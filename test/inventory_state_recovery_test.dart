import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ryza_chat_mvp/src/app_controller.dart';
import 'package:ryza_chat_mvp/src/character_state.dart';
import 'package:ryza_chat_mvp/src/ai_services.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<AppController> load() async {
    SharedPreferences.setMockInitialValues({});
    final c = await AppController.load();
    addTearDown(c.dispose);
    return c;
  }

  test('chat service exposes and executes ordinary item insertion', () async {
    final c = await load();
    c.setAgentEnabled(true);
    c.addUserMessage('把一个苹果放入背包，标签为新鲜');
    var calls = 0;
    final client = MockClient((request) async {
      final body = jsonDecode(request.body) as Map;
      Map<String, dynamic> message;
      if (calls++ == 0) {
        expect(
          (body['tools'] as List).map((t) => t['function']['name']),
          contains('add_inventory_item'),
        );
        message = {
          'role': 'assistant',
          'content': '',
          'tool_calls': [
            {
              'id': 'apple',
              'type': 'function',
              'function': {
                'name': 'add_inventory_item',
                'arguments': jsonEncode({
                  'name': '苹果',
                  'categories': ['food'],
                  'tags': ['新鲜'],
                  'quantity': 1,
                }),
              },
            },
          ],
        };
      } else {
        final result = jsonDecode((body['messages'] as List).last['content']);
        expect(result['ok'], isTrue);
        expect(result['item']['name'], '苹果');
        expect(result['item']['descriptive_tags'], ['新鲜']);
        message = {'role': 'assistant', 'content': '莱莎：苹果已经装好了。'};
      }
      return http.Response.bytes(
        utf8.encode(
          jsonEncode({
            'choices': [
              {'message': message},
            ],
          }),
        ),
        200,
        headers: {'content-type': 'application/json'},
      );
    });
    addTearDown(client.close);
    final service = OpenAiCompatibleClient(
      client: client,
      contextToolExecutor: (name, args) async => c.queryContextTool(name, args),
    );
    final output = await service
        .streamChat(
          baseUrl: 'https://example.test/v1',
          apiKey: 'test',
          model: 'test',
          systemPrompt: 'test',
          messages: c.messages,
          agentEnabled: true,
        )
        .join();
    expect(output, contains('装好了'));
    expect(calls, 2);
    expect(c.alchemyState.inventory.single.displayName, '苹果');
  });

  test('ordinary items persist with labels, reject malformed input and deduplicate retries', () async {
    final c = await load();
    c.setAgentEnabled(true);
    c.addUserMessage('把两个苹果模型放入背包，标签是纪念品');
    final args = {
      'name': '苹果模型',
      'quantity': 2,
      'categories': ['玩具'],
      'tags': ['纪念品'],
    };
    final result = c.queryContextTool('add_inventory_item', args);
    expect(jsonDecode(result)['ok'], isTrue);
    expect(c.queryContextTool('add_inventory_item', args), result);
    expect(c.alchemyState.inventory.single.quantity, 2);
    expect(
      jsonDecode(
        c.queryContextTool('add_inventory_item', {
          'name': '坏数据',
          'quantity': 1.5,
        }),
      )['ok'],
      isFalse,
    );
    expect(
      jsonDecode(c.queryContextTool('add_inventory_item', {'name': 42}))['ok'],
      isFalse,
    );
    expect(
      jsonDecode(
        c.queryContextTool('add_inventory_item', {
          'name': '坏标签',
          'tags': [42],
        }),
      )['ok'],
      isFalse,
    );
    final id = c.alchemyState.inventory.single.instanceId;
    expect(
      jsonDecode(
        c.queryContextTool('consume_inventory_item', {
          'instance_id': id,
          'quantity': 1,
          'purpose': 'eat',
        }),
      )['ok'],
      isFalse,
    );
    c.queryContextTool('consume_inventory_item', {
      'instance_id': id,
      'quantity': 1,
    });
    expect(c.alchemyState.inventory.single.customTags, ['纪念品']);
    await c.saveToLocalSlot(0);
    await c.createLocalSlot(1);
    expect(c.alchemyState.inventory, isEmpty);
    await c.loadFromLocalSlot(0);
    expect(c.alchemyState.inventory.single.quantity, 1);
    expect(c.alchemyState.inventory.single.customTags, ['纪念品']);
    await Future<void>.delayed(Duration.zero);
    final restored = await AppController.load();
    addTearDown(restored.dispose);
    expect(restored.alchemyState.inventory.single.customTags, ['纪念品']);
  });

  test('legacy slots do not inherit another save state; reset invalidates late updates', () async {
    final c = await load();
    c.characterState = CharacterState(
      values: {'mood': -80, 'energy': 5, 'closeness': 99, 'curiosity': 90},
      emotion: 'sad',
    );
    await c.saveToLocalSlot(0);
    final legacy = c.exportLocalSlot(0);
    (legacy['snapshot'] as Map).remove('characterState');
    await c.importLocalSlot(1, legacy);
    await c.loadFromLocalSlot(1);
    expect(c.characterState.values, CharacterState.newSave().values);
    expect(c.characterState.bands, CharacterState.newSave().bands);
    await c.loadFromLocalSlot(0);
    expect(c.characterState.values['energy'], 5);
    c.clearChatHistory();
    expect(c.characterState.values['energy'], 5);
    final revision = c.dataRevision;
    c.clearChatHistory(clearLongTermMemory: true);
    expect(c.characterState.values, CharacterState.newSave().values);
    expect(c.characterState.emotion, 'neutral');
    expect(
      c.settleCharacterState('late', {
        'state_delta': {'energy': -5},
        'reason': 'old',
      }, revision),
      isFalse,
    );
    expect(
      c.settleStoryTime('late', {
        'time_advance': {'kind': 'sleep', 'minutes': 480},
      }, revision),
      isFalse,
    );
    await Future<void>.delayed(Duration.zero);
    final restored = await AppController.load();
    addTearDown(restored.dispose);
    expect(restored.characterState.values, CharacterState.newSave().values);
    await c.loadFromLocalSlot(0);
    expect(c.characterState.values['energy'], 5);
  });

  test(
    'recovery works without clock, only once, and does not change story time',
    () async {
      final c = await load();
      c.characterState = CharacterState(
        values: {'mood': -50, 'energy': 5, 'closeness': 40, 'curiosity': 50},
        emotion: 'sad',
      );
      final before = c.storyClock.toJson();
      final proposal = {
        'time_advance': {'kind': 'sleep', 'minutes': 480},
      };
      expect(c.settleStoryTime('sleep', proposal, c.dataRevision), isTrue);
      expect(c.characterState.values['energy'], 80);
      expect(c.characterState.bands['energy'], 2);
      expect(c.characterState.emotion, 'sad');
      expect(c.storyClock.toJson(), before);
      expect(c.settleStoryTime('sleep', proposal, c.dataRevision), isFalse);
      expect(
        c.settleStoryTime('invalid', {
          'time_advance': {'kind': 'sleep', 'minutes': -1},
        }, c.dataRevision),
        isFalse,
      );
      expect(
        c.settleStoryTime('ordinary', {
          'time_advance': {'kind': 'conversation', 'minutes': 2},
        }, c.dataRevision),
        isFalse,
      );
      expect(
        c.settleStoryTime('short-skip', {
          'time_advance': {'kind': 'time_skip', 'minutes': 60},
        }, c.dataRevision),
        isFalse,
      );
      await c.saveToLocalSlot(0);
      await c.createLocalSlot(1);
      await c.loadFromLocalSlot(0);
      expect(c.settleStoryTime('sleep', proposal, c.dataRevision), isFalse);
    },
  );
}
