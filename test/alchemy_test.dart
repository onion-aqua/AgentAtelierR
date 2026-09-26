import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ryza_chat_mvp/src/alchemy_models.dart';
import 'package:ryza_chat_mvp/src/alchemy_screen.dart';
import 'package:ryza_chat_mvp/src/app_controller.dart';
import 'package:ryza_chat_mvp/src/app_localization.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('new game starts without gifted alchemy materials', () async {
    SharedPreferences.setMockInitialValues({});
    final controller = await AppController.load();

    expect(controller.alchemyState.inventory, isEmpty);
    expect(controller.alchemyState.history, isEmpty);
    controller.dispose();
  });

  test(
    'map gathering fills inventory and LLM-defined synthesis consumes it',
    () async {
      SharedPreferences.setMockInitialValues({});
      final controller = await AppController.load();
      final start = DateTime.utc(2026, 9, 14, 12);

      for (var index = 0; index < 12; index++) {
        controller.gatherAtCurrentLocation(
          random: Random(index + 1),
          now: start.add(Duration(seconds: index * 46)),
        );
      }
      controller.selectLocation(
        areaId: 'area_02',
        stageId: 'stage_02_005_01',
        areaName: '异界奥灵',
        stageName: '矿区',
      );
      for (var index = 0; index < 12; index++) {
        controller.gatherAtCurrentLocation(
          random: Random(index + 101),
          now: start.add(Duration(hours: 1, seconds: index * 46)),
        );
      }

      final ingredientIds = controller.alchemyState.inventory
          .take(2)
          .map((item) => item.instanceId)
          .toList(growable: false);
      expect(ingredientIds, hasLength(2));
      final before = controller.alchemyState.inventory.fold<int>(
        0,
        (total, item) => total + item.quantity,
      );
      final result = controller.synthesizeCustomItem(
        name: '旅途照明瓶',
        description: '由莱莎结合当前库存设计的幻想炼金灯。',
        category: '旅行道具',
        ingredientIds: ingredientIds,
        random: Random(301),
      );

      expect(result.templateId, 'custom_product');
      expect(result.displayName, '旅途照明瓶');
      expect(controller.alchemyState.history, hasLength(1));
      expect(
        controller.alchemyState.inventory.fold<int>(
          0,
          (total, item) => total + item.quantity,
        ),
        before - 1,
        reason:
            'two materials are consumed and one LLM-defined product is added',
      );
      await Future<void>.delayed(Duration.zero);

      final restored = await AppController.load();
      expect(restored.alchemyState.history, hasLength(1));
      expect(
        () => restored.gatherAtCurrentLocation(
          random: Random(101),
          now: start.add(const Duration(hours: 1, seconds: 10)),
        ),
        throwsA(isA<GatherCooldownException>()),
      );
      controller.dispose();
      restored.dispose();
    },
  );

  test('alchemy quality and conflicting traits are resolved locally', () {
    final now = DateTime.utc(2026, 9, 14);
    AlchemyItem item(String id, String template, List<String> tags) =>
        AlchemyItem(
          instanceId: id,
          templateId: template,
          quality: 72,
          quantity: 1,
          tagIds: tags,
          acquiredAt: now,
        );
    final result = const AlchemyEngine().synthesizeCustom(
      name: '测试调合物',
      description: '用于验证本地品质和冲突特性处理。',
      category: '测试道具',
      ingredients: [
        item('uni', 'uni', ['durable', 'fragile', 'high_price']),
        item('sand', 'flammable_sand', ['fire', 'cheap', 'unstable']),
      ],
      random: Random(7),
      now: now,
    );

    final groups = result.tagIds
        .map((id) => AlchemyCatalog.tags[id]?.conflictGroup)
        .whereType<String>()
        .toList();
    expect(result.quality, inInclusiveRange(67, 77));
    expect(result.tagIds.toSet().length, result.tagIds.length);
    expect(groups.toSet().length, groups.length);
  });

  test(
    'LLM discoveries outside the catalog are validated and persisted',
    () async {
      SharedPreferences.setMockInitialValues({});
      final controller = await AppController.load();
      final gatheredAt = DateTime.utc(2026, 9, 14, 14);
      controller.selectLocation(
        areaId: 'area_02',
        stageId: 'stage_02_005_01',
        areaName: '异界奥灵',
        stageName: '矿区',
      );
      final node = AlchemyCatalog.gatherNodeForLocation(
        areaId: controller.selectedAreaId,
        stageId: controller.selectedStageId,
      );

      final gathered = controller.gatherAtCurrentLocation(
        random: Random(47),
        now: gatheredAt,
        discoveries: const [
          GatherDiscovery(
            name: '星雾苔',
            description: '附着在晶石缝里，轻触时会散出微凉的星屑。',
            categories: ['plant', 'water', '异界素材'],
            suggestedTagIds: ['cooling', 'stable', 'fragile'],
          ),
        ],
      );

      final item = gathered.items.single;
      expect(item.displayName, '星雾苔');
      expect(item.description, contains('微凉'));
      expect(item.type, AlchemyItemType.material);
      expect(item.quantity, inInclusiveRange(1, 3));
      expect(item.quality, inInclusiveRange(node.minQuality, node.maxQuality));
      expect(item.categories, containsAll(['plant', 'water', '异界素材']));
      expect(controller.alchemyState.inventory.single.displayName, '星雾苔');

      final restored = AlchemyState.fromJson(controller.alchemyState.toJson());
      final restoredItem = restored.inventory.single;
      expect(restoredItem.displayName, item.displayName);
      expect(restoredItem.description, item.description);
      expect(restoredItem.categories, item.categories);
      expect(restoredItem.type, AlchemyItemType.material);
      expect(
        () => controller.gatherAtCurrentLocation(
          now: gatheredAt.add(const Duration(seconds: 1)),
          discoveries: const [
            GatherDiscovery(
              name: '后续素材',
              description: '这次采集应当被冷却阻止。',
              categories: ['plant'],
            ),
          ],
        ),
        throwsA(isA<GatherCooldownException>()),
      );
      controller.dispose();
    },
  );

  test(
    'LLM-defined recipes accept discovered materials without a fixed catalog',
    () {
      final now = DateTime.utc(2026, 9, 14);
      AlchemyItem discovered(String id, String name, String category) =>
          AlchemyItem(
            instanceId: id,
            templateId: 'custom_material',
            quality: 60,
            quantity: 1,
            tagIds: const ['stable'],
            acquiredAt: now,
            customName: name,
            customDescription: '由地图采集发现的清单外素材。',
            customCategories: [category],
            customType: AlchemyItemType.material,
          );

      final result = const AlchemyEngine().synthesizeCustom(
        name: '回声火种',
        description: '结合响尾果与燐火砂制成的幻想炼金道具。',
        category: '探索道具',
        ingredients: [
          discovered('custom_explosive', '响尾果', 'explosive'),
          discovered('custom_fuel', '燐火砂', 'fuel'),
        ],
        random: Random(9),
        now: now,
      );

      expect(result.templateId, 'custom_product');
      expect(result.displayName, '回声火种');
    },
  );

  test('synthesized item language follows UI language', () async {
    SharedPreferences.setMockInitialValues({});
    final controller = await AppController.load();
    controller.configureLanguages(
      interface: AppLanguage.english,
      narrator: AppLanguage.chinese,
      characterReply: AppLanguage.japanese,
      translation: TranslationLanguage.none,
    );
    controller.setAgentEnabled(true);
    controller.alchemyState = AlchemyState(
      inventory: [
        AlchemyItem(
          instanceId: 'finished_uni',
          templateId: 'explosive_uni',
          quality: 72,
          quantity: 1,
          tagIds: const ['fire'],
          acquiredAt: DateTime.utc(2026, 9, 14),
        ),
      ],
      history: const [],
    );

    final prompt = controller.buildCharacterPrompt(
      currentInput: '調合で旅行用品を作ろう。',
    );
    final inventory = jsonDecode(
      controller.queryContextTool('inspect_alchemy_inventory', const {}),
    ) as Map<String, dynamic>;
    final item = (inventory['inventory'] as List).single as Map;

    expect(prompt, contains('当前界面语言 English'));
    expect(item['name'], 'Explosive Uni');
    expect(item['description'], contains('throwable alchemical item'));
    expect(inventory, isNot(contains('known_recipes')));
    expect(inventory['recipe_source'], 'llm_generated');
    controller.dispose();
  });

  test(
    'dialogue tools require travel then gather and synthesize locally',
    () async {
      SharedPreferences.setMockInitialValues({});
      final controller = await AppController.load();
      controller.setAgentEnabled(true);

      final blocked = jsonDecode(
        controller.queryContextTool('gather_current_location', const {}),
      ) as Map<String, dynamic>;
      expect(blocked['ok'], isFalse);
      expect(blocked['error'], 'travel_required');

      controller.selectLocation(
        areaId: 'area_01',
        stageId: 'stage_01_002_01',
        areaName: '库肯岛周边地域',
        stageName: '小妖精之森・隐居处前',
      );
      final gathered = jsonDecode(
        controller.queryContextTool('gather_current_location', const {
          'discoveries': [
            {
              'name': '森息露珠',
              'description': '小妖精之森里凝结的清澈露珠。',
              'categories': ['water', 'plant'],
              'suggested_trait_ids': ['cooling', 'healing'],
            },
          ],
        }),
      ) as Map<String, dynamic>;
      expect(gathered['ok'], isTrue);
      expect(gathered['items'], isNotEmpty);
      expect(gathered['discovery_source'], 'llm_scene_discovery');
      expect(
        ((gathered['items'] as List).single as Map<String, dynamic>)['name'],
        '森息露珠',
      );

      final inventory = jsonDecode(
        controller.queryContextTool('inspect_alchemy_inventory', const {}),
      ) as Map<String, dynamic>;
      final items = inventory['inventory'] as List<dynamic>;
      final first = items.first as Map<String, dynamic>;
      final synthesis = jsonDecode(
        controller.queryContextTool('synthesize_custom_item', {
          'name': '旅行保温杯',
          'description': '用幻想炼金制成的便携式杯子。',
          'category': '生活用品',
          'intended_effect': '在旅途中让饮品保持合适温度',
          'ingredient_instance_ids': [first['instance_id']],
        }),
      ) as Map<String, dynamic>;

      expect(synthesis['ok'], isTrue);
      expect(synthesis['kind'], 'llm_recipe');
      expect((synthesis['result'] as Map<String, dynamic>)['name'], '旅行保温杯');
      expect(controller.alchemyState.history.first.result.isCustom, isTrue);
      expect(controller.alchemyState.history.first.result.displayName, '旅行保温杯');

      final restored = AlchemyState.fromJson(controller.alchemyState.toJson());
      expect(restored.history.first.result.displayName, '旅行保温杯');
      expect(
        restored.inventory.any((item) => item.displayName == '旅行保温杯'),
        isTrue,
      );
      controller.dispose();
    },
  );

  test('version 2 alchemy saves remain readable', () {
    final restored = AlchemyState.fromJson({
      'version': 2,
      'inventory': [
        {
          'instanceId': 'legacy_water',
          'templateId': 'clean_water',
          'quality': 50,
          'quantity': 2,
          'tagIds': ['cooling'],
          'acquiredAt': '2026-09-14T00:00:00.000Z',
        },
      ],
      'history': <dynamic>[],
    });

    expect(restored.inventory.single.displayName, '清水');
    expect(restored.inventory.single.quantity, 2);
  });

  test('large inventory stacks survive save and restore', () {
    final acquiredAt = DateTime.utc(2026, 9, 26);
    final state = AlchemyState(
      inventory: [
        for (var index = 0; index < 256; index++)
          AlchemyItem(
            instanceId: 'item_$index',
            templateId: 'custom_material',
            quality: 60,
            quantity: index == 0 ? 2048 : 1,
            tagIds: const [],
            acquiredAt: acquiredAt,
            customName: '素材 $index',
            customType: AlchemyItemType.material,
          ),
      ],
      history: const [],
    );

    final restored = AlchemyState.fromJson(
      jsonDecode(jsonEncode(state.toJson())) as Map<String, dynamic>,
    );

    expect(restored.inventory, hasLength(256));
    expect(restored.inventory.first.quantity, 2048);
    expect(restored.inventory.last.displayName, '素材 255');
  });

  test(
    'alchemy state participates in local slots and on-demand prompts',
    () async {
      SharedPreferences.setMockInitialValues({});
      final controller = await AppController.load();
      final gathered = controller.gatherAtCurrentLocation(
        random: Random(23),
        now: DateTime.utc(2026, 9, 14, 18),
      );
      await controller.saveToLocalSlot(0);
      controller.alchemyState = AlchemyState.empty();
      await controller.loadFromLocalSlot(0);

      expect(controller.alchemyState.inventory, isNotEmpty);
      expect(controller.exportData()['alchemy'], isA<Map<String, dynamic>>());
      final alchemyPrompt = controller.buildCharacterPrompt(
        currentInput: '刚才采集到的素材在背包里吗？',
      );
      expect(alchemyPrompt, contains('本地炼金状态'));
      expect(
        alchemyPrompt,
        contains(
          AlchemyCatalog.templates[gathered.items.first.templateId]!.name,
        ),
      );
      expect(
        controller.buildCharacterPrompt(currentInput: '今天天气怎么样？'),
        isNot(contains('本地炼金状态')),
        reason: 'unrelated turns must not pay the alchemy prompt token cost',
      );
      controller.setAgentEnabled(true);
      expect(
        controller.buildCharacterPrompt(currentInput: '我们去摘一些附近的果子吧。'),
        contains('gather_current_location'),
        reason: 'natural gathering verbs must activate the local tool rules',
      );
      controller.dispose();
    },
  );

  testWidgets('alchemy screen only shows inventory and history', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final controller = (await tester.runAsync(AppController.load))!;
    await tester.pumpWidget(
      MaterialApp(home: AlchemyScreen(controller: controller)),
    );

    expect(find.text('炼金工房'), findsOneWidget);
    expect(find.text('配方'), findsNothing);
    expect(find.text('背包'), findsOneWidget);
    expect(find.text('记录'), findsOneWidget);
    expect(find.text('爆裂海胆'), findsNothing);
    expect(find.textContaining('背包是空的'), findsOneWidget);
    expect(find.byType(Image), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });
}
