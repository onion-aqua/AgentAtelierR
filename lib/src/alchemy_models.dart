import 'dart:math';

import 'app_localization.dart';

enum AlchemyItemType { material, catalyst, product }

class AlchemyTag {
  const AlchemyTag({
    required this.id,
    required this.name,
    required this.weight,
    this.conflictGroup,
  });

  final String id;
  final String name;
  final double weight;
  final String? conflictGroup;
}

class AlchemyItemTemplate {
  const AlchemyItemTemplate({
    required this.id,
    required this.name,
    required this.type,
    required this.categories,
    this.description = '',
    this.englishName = '',
    this.japaneseName = '',
    this.englishDescription = '',
    this.japaneseDescription = '',
  });

  final String id;
  final String name;
  final AlchemyItemType type;
  final Set<String> categories;
  final String description;
  final String englishName;
  final String japaneseName;
  final String englishDescription;
  final String japaneseDescription;

  String localizedName(AppLanguage language) => switch (language) {
    AppLanguage.chinese => name,
    AppLanguage.english => englishName.isEmpty ? name : englishName,
    AppLanguage.japanese => japaneseName.isEmpty ? name : japaneseName,
  };

  String localizedDescription(AppLanguage language) => switch (language) {
    AppLanguage.chinese => description,
    AppLanguage.english =>
      englishDescription.isEmpty ? description : englishDescription,
    AppLanguage.japanese =>
      japaneseDescription.isEmpty ? description : japaneseDescription,
  };
}

class AlchemyItem {
  const AlchemyItem({
    required this.instanceId,
    required this.templateId,
    required this.quality,
    required this.quantity,
    required this.tagIds,
    required this.acquiredAt,
    this.customName,
    this.customDescription,
    this.customCategories = const [],
    this.customType,
  });

  final String instanceId;
  final String templateId;
  final int quality;
  final int quantity;
  final List<String> tagIds;
  final DateTime acquiredAt;
  final String? customName;
  final String? customDescription;
  final List<String> customCategories;
  final AlchemyItemType? customType;

  bool get isCustom => customName?.trim().isNotEmpty == true;

  String get displayName => isCustom
      ? customName!.trim()
      : AlchemyCatalog.templates[templateId]?.name ?? templateId;

  String displayNameFor(AppLanguage language) => isCustom
      ? customName!.trim()
      : AlchemyCatalog.templates[templateId]?.localizedName(language) ??
            templateId;

  String get description => isCustom
      ? customDescription?.trim() ?? ''
      : AlchemyCatalog.templates[templateId]?.description ?? '';

  String descriptionFor(AppLanguage language) => isCustom
      ? customDescription?.trim() ?? ''
      : AlchemyCatalog.templates[templateId]?.localizedDescription(language) ??
            '';

  Set<String> get categories => isCustom
      ? customCategories.toSet()
      : AlchemyCatalog.templates[templateId]?.categories ?? const {};

  AlchemyItemType get type =>
      customType ??
      AlchemyCatalog.templates[templateId]?.type ??
      AlchemyItemType.product;

  String get qualityRank => switch (quality) {
    >= 90 => 'S',
    >= 80 => 'A',
    >= 70 => 'B',
    >= 55 => 'C',
    >= 35 => 'D',
    _ => 'E',
  };

  AlchemyItem copyWith({int? quantity}) => AlchemyItem(
    instanceId: instanceId,
    templateId: templateId,
    quality: quality,
    quantity: quantity ?? this.quantity,
    tagIds: tagIds,
    acquiredAt: acquiredAt,
    customName: customName,
    customDescription: customDescription,
    customCategories: customCategories,
    customType: customType,
  );

  Map<String, dynamic> toJson() => {
    'instanceId': instanceId,
    'templateId': templateId,
    'quality': quality,
    'quantity': quantity,
    'tagIds': tagIds,
    'acquiredAt': acquiredAt.toIso8601String(),
    if (isCustom) 'customName': customName,
    if (customDescription?.trim().isNotEmpty == true)
      'customDescription': customDescription,
    if (customCategories.isNotEmpty) 'customCategories': customCategories,
    if (customType != null) 'customType': customType!.name,
  };

  factory AlchemyItem.fromJson(Map<String, dynamic> json) {
    final instanceId = json['instanceId'];
    final templateId = json['templateId'];
    if (instanceId is! String || templateId is! String) {
      throw const FormatException('炼金物品数据缺少标识');
    }
    return AlchemyItem(
      instanceId: instanceId,
      templateId: templateId,
      quality: (json['quality'] as num? ?? 0).round().clamp(0, 100),
      quantity: (json['quantity'] as num? ?? 1).round().clamp(1, 9999),
      tagIds: (json['tagIds'] as List<dynamic>? ?? const [])
          .whereType<String>()
          .where(AlchemyCatalog.tags.containsKey)
          .toList(growable: false),
      acquiredAt:
          DateTime.tryParse(json['acquiredAt'] as String? ?? '') ??
          DateTime.now(),
      customName: (json['customName'] as String?)?.trim(),
      customDescription: (json['customDescription'] as String?)?.trim(),
      customCategories: (json['customCategories'] as List<dynamic>? ?? const [])
          .whereType<String>()
          .map((value) => value.trim())
          .where((value) => value.isNotEmpty)
          .take(6)
          .toList(growable: false),
      customType: AlchemyItemType.values
          .where((value) => value.name == json['customType'])
          .firstOrNull,
    );
  }
}

class AlchemyHistoryEntry {
  const AlchemyHistoryEntry({
    required this.result,
    required this.recipeId,
    required this.createdAt,
  });

  final AlchemyItem result;
  final String recipeId;
  final DateTime createdAt;

  Map<String, dynamic> toJson() => {
    'result': result.toJson(),
    'recipeId': recipeId,
    'createdAt': createdAt.toIso8601String(),
  };

  factory AlchemyHistoryEntry.fromJson(Map<String, dynamic> json) {
    final result = json['result'];
    if (result is! Map) throw const FormatException('炼金记录缺少成品');
    return AlchemyHistoryEntry(
      result: AlchemyItem.fromJson(Map<String, dynamic>.from(result)),
      recipeId: json['recipeId'] as String? ?? '',
      createdAt:
          DateTime.tryParse(json['createdAt'] as String? ?? '') ??
          DateTime.now(),
    );
  }
}

class AlchemyState {
  const AlchemyState({
    required this.inventory,
    required this.history,
    this.gatherAvailableAtByStage = const {},
  });

  factory AlchemyState.empty() =>
      const AlchemyState(inventory: [], history: []);

  final List<AlchemyItem> inventory;
  final List<AlchemyHistoryEntry> history;
  final Map<String, DateTime> gatherAvailableAtByStage;

  Map<String, dynamic> toJson() => {
    'version': 4,
    'inventory': inventory.map((item) => item.toJson()).toList(),
    'history': history.map((entry) => entry.toJson()).toList(),
    'gatherAvailableAtByStage': gatherAvailableAtByStage.map(
      (stageId, availableAt) =>
          MapEntry(stageId, availableAt.toIso8601String()),
    ),
  };

  factory AlchemyState.fromJson(Map<String, dynamic> json) {
    final version = (json['version'] as num?)?.toInt() ?? 1;
    if (version < 1 || version > 4) {
      throw const FormatException('不支持的炼金存档版本');
    }
    final cooldowns = <String, DateTime>{};
    final rawCooldowns =
        json['gatherAvailableAtByStage'] as Map<dynamic, dynamic>? ?? const {};
    for (final entry in rawCooldowns.entries) {
      if (entry.key is! String || entry.value is! String) continue;
      final value = DateTime.tryParse(entry.value as String);
      if (value != null) cooldowns[entry.key as String] = value;
    }
    return AlchemyState(
      inventory: (json['inventory'] as List<dynamic>? ?? const [])
          .whereType<Map>()
          .map(
            (value) => AlchemyItem.fromJson(Map<String, dynamic>.from(value)),
          )
          .where(
            (item) =>
                item.isCustom ||
                AlchemyCatalog.templates.containsKey(item.templateId),
          )
          .toList(),
      history: (json['history'] as List<dynamic>? ?? const [])
          .whereType<Map>()
          .map(
            (value) =>
                AlchemyHistoryEntry.fromJson(Map<String, dynamic>.from(value)),
          )
          .where(
            (entry) =>
                entry.result.isCustom ||
                AlchemyCatalog.templates.containsKey(entry.result.templateId),
          )
          .toList(),
      gatherAvailableAtByStage: cooldowns,
    );
  }
}

class GatherDrop {
  const GatherDrop({
    required this.templateId,
    required this.weight,
    required this.minQuantity,
    required this.maxQuantity,
    required this.tagIds,
  });

  final String templateId;
  final int weight;
  final int minQuantity;
  final int maxQuantity;
  final List<String> tagIds;
}

class GatherNode {
  const GatherNode({
    required this.id,
    required this.name,
    required this.drops,
    required this.minQuality,
    required this.maxQuality,
    this.respawnSeconds = 45,
  });

  final String id;
  final String name;
  final List<GatherDrop> drops;
  final int minQuality;
  final int maxQuality;
  final int respawnSeconds;
}

class GatherResult {
  const GatherResult({
    required this.node,
    required this.items,
    required this.gatheredAt,
    required this.nextAvailableAt,
  });

  final GatherNode node;
  final List<AlchemyItem> items;
  final DateTime gatheredAt;
  final DateTime nextAvailableAt;
}

class GatherDiscovery {
  const GatherDiscovery({
    required this.name,
    required this.description,
    required this.categories,
    this.suggestedTagIds = const [],
  });

  final String name;
  final String description;
  final List<String> categories;
  final List<String> suggestedTagIds;
}

class GatherCooldownException implements Exception {
  const GatherCooldownException(this.remaining);

  final Duration remaining;

  @override
  String toString() => '采集点尚未恢复';
}

class AlchemyCatalog {
  static const tags = <String, AlchemyTag>{
    'high_price': AlchemyTag(
      id: 'high_price',
      name: '高价',
      weight: 0.8,
      conflictGroup: 'price',
    ),
    'cheap': AlchemyTag(
      id: 'cheap',
      name: '廉价',
      weight: 0.7,
      conflictGroup: 'price',
    ),
    'durable': AlchemyTag(
      id: 'durable',
      name: '耐用',
      weight: 1,
      conflictGroup: 'durability',
    ),
    'fragile': AlchemyTag(
      id: 'fragile',
      name: '易损',
      weight: 0.65,
      conflictGroup: 'durability',
    ),
    'fire': AlchemyTag(id: 'fire', name: '火属性', weight: 1),
    'cooling': AlchemyTag(id: 'cooling', name: '清凉', weight: 1),
    'healing': AlchemyTag(id: 'healing', name: '恢复力', weight: 1),
    'stable': AlchemyTag(
      id: 'stable',
      name: '稳定',
      weight: 1,
      conflictGroup: 'stability',
    ),
    'unstable': AlchemyTag(
      id: 'unstable',
      name: '不稳定',
      weight: 0.75,
      conflictGroup: 'stability',
    ),
  };

  static const templates = <String, AlchemyItemTemplate>{
    'uni': AlchemyItemTemplate(
      id: 'uni',
      name: '海胆',
      englishName: 'Uni',
      japaneseName: 'うに',
      type: AlchemyItemType.material,
      categories: {'explosive'},
    ),
    'flammable_sand': AlchemyItemTemplate(
      id: 'flammable_sand',
      name: '可燃之砂',
      englishName: 'Flammable Sand',
      japaneseName: '可燃性の砂',
      type: AlchemyItemType.material,
      categories: {'fuel'},
    ),
    'clean_water': AlchemyItemTemplate(
      id: 'clean_water',
      name: '清水',
      englishName: 'Clean Water',
      japaneseName: 'きれいな水',
      type: AlchemyItemType.material,
      categories: {'water'},
    ),
    'blue_herb': AlchemyItemTemplate(
      id: 'blue_herb',
      name: '蓝色药草',
      englishName: 'Blue Herb',
      japaneseName: '青い薬草',
      type: AlchemyItemType.material,
      categories: {'plant'},
    ),
    'weathered_ore': AlchemyItemTemplate(
      id: 'weathered_ore',
      name: '风化矿石',
      englishName: 'Weathered Ore',
      japaneseName: '風化した鉱石',
      type: AlchemyItemType.material,
      categories: {'ore', 'stone'},
      description: '在矿道与遗迹附近常见的基础矿石。',
      englishDescription: 'A basic ore commonly found near mines and ruins.',
      japaneseDescription: '鉱道や遺跡の近くでよく見つかる基礎的な鉱石。',
    ),
    'quality_catalyst': AlchemyItemTemplate(
      id: 'quality_catalyst',
      name: '品质调和剂',
      englishName: 'Quality Catalyst',
      japaneseName: '品質調整剤',
      type: AlchemyItemType.catalyst,
      categories: {'catalyst'},
      description: '少量提高成品品质，并增加一个标签槽位。',
      englishDescription:
          'Slightly raises the finished item quality and adds one trait slot.',
      japaneseDescription: '完成品の品質を少し上げ、特性スロットを1つ追加する。',
    ),
    'explosive_uni': AlchemyItemTemplate(
      id: 'explosive_uni',
      name: '爆裂海胆',
      englishName: 'Explosive Uni',
      japaneseName: '爆裂うに',
      type: AlchemyItemType.product,
      categories: {'bomb'},
      description: '将海胆的尖刺与可燃素材结合而成的投掷炼金物。',
      englishDescription: 'A throwable alchemical item combining Uni spikes with combustible material.',
      japaneseDescription: 'うにのトゲと可燃性素材を組み合わせた投擲用の調合アイテム。',
    ),
    'blue_neutralizer': AlchemyItemTemplate(
      id: 'blue_neutralizer',
      name: '中和剂·蓝',
      englishName: 'Blue Neutralizer',
      japaneseName: '中和剤・青',
      type: AlchemyItemType.product,
      categories: {'neutralizer'},
      description: '适合水属性调合的基础中和剂。',
      englishDescription:
          'A basic neutralizer suited to water-aligned synthesis.',
      japaneseDescription: '水属性の調合に適した基礎的な中和剤。',
    ),
  };

  static const gatherNodes = <String, GatherNode>{
    'forest': GatherNode(
      id: 'forest',
      name: '森林采集点',
      minQuality: 38,
      maxQuality: 82,
      drops: [
        GatherDrop(
          templateId: 'blue_herb',
          weight: 50,
          minQuantity: 1,
          maxQuantity: 3,
          tagIds: ['healing', 'cooling', 'durable', 'high_price'],
        ),
        GatherDrop(
          templateId: 'uni',
          weight: 30,
          minQuantity: 1,
          maxQuantity: 2,
          tagIds: ['durable', 'fragile', 'high_price', 'cheap'],
        ),
        GatherDrop(
          templateId: 'clean_water',
          weight: 20,
          minQuantity: 1,
          maxQuantity: 2,
          tagIds: ['cooling', 'stable'],
        ),
      ],
    ),
    'waterside': GatherNode(
      id: 'waterside',
      name: '水边采集点',
      minQuality: 42,
      maxQuality: 86,
      drops: [
        GatherDrop(
          templateId: 'clean_water',
          weight: 55,
          minQuantity: 1,
          maxQuantity: 3,
          tagIds: ['cooling', 'stable', 'high_price'],
        ),
        GatherDrop(
          templateId: 'blue_herb',
          weight: 30,
          minQuantity: 1,
          maxQuantity: 2,
          tagIds: ['healing', 'cooling', 'durable'],
        ),
        GatherDrop(
          templateId: 'uni',
          weight: 15,
          minQuantity: 1,
          maxQuantity: 2,
          tagIds: ['durable', 'fragile', 'cheap'],
        ),
      ],
    ),
    'mine': GatherNode(
      id: 'mine',
      name: '矿区采集点',
      minQuality: 45,
      maxQuality: 90,
      drops: [
        GatherDrop(
          templateId: 'flammable_sand',
          weight: 50,
          minQuantity: 1,
          maxQuantity: 3,
          tagIds: ['fire', 'stable', 'unstable', 'cheap'],
        ),
        GatherDrop(
          templateId: 'weathered_ore',
          weight: 35,
          minQuantity: 1,
          maxQuantity: 2,
          tagIds: ['durable', 'fragile', 'high_price', 'cheap'],
        ),
        GatherDrop(
          templateId: 'quality_catalyst',
          weight: 15,
          minQuantity: 1,
          maxQuantity: 1,
          tagIds: ['stable', 'high_price'],
        ),
      ],
    ),
    'town': GatherNode(
      id: 'town',
      name: '城镇采集点',
      minQuality: 30,
      maxQuality: 68,
      drops: [
        GatherDrop(
          templateId: 'blue_herb',
          weight: 40,
          minQuantity: 1,
          maxQuantity: 2,
          tagIds: ['healing', 'cheap', 'durable'],
        ),
        GatherDrop(
          templateId: 'clean_water',
          weight: 35,
          minQuantity: 1,
          maxQuantity: 2,
          tagIds: ['cooling', 'stable', 'cheap'],
        ),
        GatherDrop(
          templateId: 'flammable_sand',
          weight: 25,
          minQuantity: 1,
          maxQuantity: 1,
          tagIds: ['fire', 'cheap', 'unstable'],
        ),
      ],
    ),
    'ruins': GatherNode(
      id: 'ruins',
      name: '遗迹采集点',
      minQuality: 50,
      maxQuality: 94,
      drops: [
        GatherDrop(
          templateId: 'weathered_ore',
          weight: 40,
          minQuantity: 1,
          maxQuantity: 2,
          tagIds: ['durable', 'fragile', 'high_price', 'stable'],
        ),
        GatherDrop(
          templateId: 'flammable_sand',
          weight: 35,
          minQuantity: 1,
          maxQuantity: 2,
          tagIds: ['fire', 'unstable', 'high_price'],
        ),
        GatherDrop(
          templateId: 'quality_catalyst',
          weight: 25,
          minQuantity: 1,
          maxQuantity: 1,
          tagIds: ['stable', 'high_price'],
        ),
      ],
    ),
    'common': GatherNode(
      id: 'common',
      name: '野外采集点',
      minQuality: 35,
      maxQuality: 78,
      drops: [
        GatherDrop(
          templateId: 'blue_herb',
          weight: 30,
          minQuantity: 1,
          maxQuantity: 2,
          tagIds: ['healing', 'durable', 'cheap'],
        ),
        GatherDrop(
          templateId: 'uni',
          weight: 25,
          minQuantity: 1,
          maxQuantity: 2,
          tagIds: ['durable', 'fragile', 'cheap'],
        ),
        GatherDrop(
          templateId: 'clean_water',
          weight: 25,
          minQuantity: 1,
          maxQuantity: 2,
          tagIds: ['cooling', 'stable'],
        ),
        GatherDrop(
          templateId: 'flammable_sand',
          weight: 20,
          minQuantity: 1,
          maxQuantity: 2,
          tagIds: ['fire', 'unstable', 'cheap'],
        ),
      ],
    ),
  };

  static GatherNode gatherNodeForLocation({
    required String areaId,
    required String stageId,
  }) {
    const waterStages = {
      'stage_01_001_01',
      'stage_01_001_08',
      'stage_01_003_01',
      'stage_01_013_04',
      'stage_02_001_02',
      'stage_02_004_04',
      'stage_02_004_05',
      'stage_02_004_06',
      'stage_02_005_02',
      'stage_03_001_01',
      'stage_03_001_05',
      'stage_03_003_02',
      'stage_03_003_03',
      'stage_05_009_01',
    };
    if (waterStages.contains(stageId)) return gatherNodes['waterside']!;

    final parts = stageId.split('_');
    final fieldId = parts.length >= 4 ? 'field_${parts[1]}_${parts[2]}' : '';
    const forestFields = {
      'field_01_002',
      'field_01_008',
      'field_03_002',
      'field_03_003',
    };
    const waterFields = {'field_01_004', 'field_01_005', 'field_01_013'};
    const mineFields = {
      'field_01_007',
      'field_01_009',
      'field_02_001',
      'field_02_003',
      'field_02_004',
      'field_02_005',
      'field_03_004',
    };
    const townFields = {
      'field_01_001',
      'field_02_002',
      'field_03_001',
      'field_05_001',
      'field_05_002',
    };
    const ruinFields = {
      'field_01_003',
      'field_01_006',
      'field_01_010',
      'field_01_011',
      'field_01_012',
      'field_01_014',
      'field_03_005',
      'field_05_006',
      'field_05_007',
      'field_05_008',
      'field_05_010',
    };
    if (forestFields.contains(fieldId)) return gatherNodes['forest']!;
    if (waterFields.contains(fieldId)) return gatherNodes['waterside']!;
    if (mineFields.contains(fieldId)) return gatherNodes['mine']!;
    if (townFields.contains(fieldId)) return gatherNodes['town']!;
    if (ruinFields.contains(fieldId) || areaId == 'area_04') {
      return gatherNodes['ruins']!;
    }
    return gatherNodes['common']!;
  }
}

class AlchemyEngine {
  const AlchemyEngine();

  double successChance(List<AlchemyItem> ingredients, {AlchemyItem? catalyst}) {
    if (ingredients.isEmpty) return 0;
    final quality =
        ingredients.fold<int>(0, (sum, item) => sum + item.quality) /
        ingredients.length;
    return (0.60 + quality * 0.003 + (catalyst == null ? 0 : 0.08)).clamp(
      0.60,
      0.95,
    );
  }

  AlchemyItem synthesizeCustom({
    required String name,
    required String description,
    required List<AlchemyItem> ingredients,
    String category = '',
    AlchemyItem? catalyst,
    Random? random,
    DateTime? now,
  }) {
    if (ingredients.isEmpty || ingredients.length > 6) {
      throw const FormatException('自定义调合需要 1 至 6 份素材');
    }
    if (catalyst != null && catalyst.type != AlchemyItemType.catalyst) {
      throw const FormatException('所选物品不是调和剂');
    }
    return _createResult(
      templateId: 'custom_product',
      ingredients: ingredients,
      catalyst: catalyst,
      random: random,
      now: now,
      customName: name,
      customDescription: description,
      customCategories: category.isEmpty ? const [] : [category],
    );
  }

  AlchemyItem _createResult({
    required String templateId,
    required List<AlchemyItem> ingredients,
    required AlchemyItem? catalyst,
    required Random? random,
    required DateTime? now,
    String? customName,
    String? customDescription,
    List<String> customCategories = const [],
  }) {
    final rng = random ?? Random.secure();
    final average =
        ingredients.fold<int>(0, (sum, item) => sum + item.quality) /
        ingredients.length;
    final quality =
        (average + rng.nextInt(11) - 5 + (catalyst == null ? 0 : 10))
            .round()
            .clamp(0, 100);
    final candidates = <AlchemyTag>[];
    for (final item in [...ingredients, ?catalyst]) {
      for (final id in item.tagIds) {
        final tag = AlchemyCatalog.tags[id];
        if (tag != null && rng.nextDouble() <= tag.weight.clamp(0, 1)) {
          candidates.add(tag);
        }
      }
    }
    candidates.shuffle(rng);
    final limit = (quality >= 80 ? 3 : 2) + (catalyst == null ? 0 : 1);
    final selected = <AlchemyTag>[];
    final usedGroups = <String>{};
    for (final tag in candidates) {
      if (selected.any((value) => value.id == tag.id)) continue;
      final group = tag.conflictGroup;
      if (group != null && !usedGroups.add(group)) continue;
      selected.add(tag);
      if (selected.length >= limit.clamp(2, 4)) break;
    }
    final createdAt = now ?? DateTime.now();
    return AlchemyItem(
      instanceId: 'alchemy_${createdAt.microsecondsSinceEpoch}',
      templateId: templateId,
      quality: quality,
      quantity: 1,
      tagIds: selected.map((tag) => tag.id).toList(growable: false),
      acquiredAt: createdAt,
      customName: customName,
      customDescription: customDescription,
      customCategories: customCategories,
    );
  }
}

class GatherEngine {
  const GatherEngine();

  GatherResult gather({
    required GatherNode node,
    Random? random,
    DateTime? now,
  }) {
    if (node.drops.isEmpty) {
      throw const FormatException('该采集点没有可获取的素材');
    }
    final rng = random ?? Random.secure();
    final gatheredAt = now ?? DateTime.now();
    final remainingDrops = node.drops.toList();
    final groupCount = 1 + rng.nextInt(min(3, remainingDrops.length));
    final items = <AlchemyItem>[];
    for (var index = 0; index < groupCount; index++) {
      final drop = _takeWeightedDrop(remainingDrops, rng);
      final quantity =
          drop.minQuantity +
          rng.nextInt(drop.maxQuantity - drop.minQuantity + 1);
      final quality =
          node.minQuality + rng.nextInt(node.maxQuality - node.minQuality + 1);
      final candidateTags =
          drop.tagIds
              .map((id) => AlchemyCatalog.tags[id])
              .whereType<AlchemyTag>()
              .toList()
            ..shuffle(rng);
      final maxTags = quality >= 80 ? 3 : (quality >= 55 ? 2 : 1);
      final selectedTags = <AlchemyTag>[];
      final conflictGroups = <String>{};
      for (final tag in candidateTags) {
        final group = tag.conflictGroup;
        if (group != null && !conflictGroups.add(group)) continue;
        selectedTags.add(tag);
        if (selectedTags.length >= maxTags) break;
      }
      final tagIds = selectedTags.map((tag) => tag.id).toList()..sort();
      items.add(
        AlchemyItem(
          instanceId:
              'gather_${gatheredAt.microsecondsSinceEpoch}_${index + 1}',
          templateId: drop.templateId,
          quality: quality,
          quantity: quantity,
          tagIds: tagIds,
          acquiredAt: gatheredAt,
        ),
      );
    }
    return GatherResult(
      node: node,
      items: items,
      gatheredAt: gatheredAt,
      nextAvailableAt: gatheredAt.add(Duration(seconds: node.respawnSeconds)),
    );
  }

  GatherResult gatherDiscoveries({
    required GatherNode node,
    required List<GatherDiscovery> discoveries,
    Random? random,
    DateTime? now,
  }) {
    if (discoveries.isEmpty || discoveries.length > 3) {
      throw const FormatException('每次只能发现 1 至 3 种素材');
    }
    final rng = random ?? Random.secure();
    final gatheredAt = now ?? DateTime.now();
    final items = <AlchemyItem>[];
    for (var index = 0; index < discoveries.length; index++) {
      final discovery = discoveries[index];
      final quality =
          node.minQuality + rng.nextInt(node.maxQuality - node.minQuality + 1);
      final candidates = discovery.suggestedTagIds
          .where(AlchemyCatalog.tags.containsKey)
          .toSet()
          .toList();
      if (candidates.isEmpty) {
        candidates.addAll(_inferredTagIds(discovery));
      }
      candidates.shuffle(rng);
      final maxTags = quality >= 80 ? 3 : (quality >= 55 ? 2 : 1);
      final selectedTagIds = <String>[];
      final usedGroups = <String>{};
      for (final id in candidates) {
        final tag = AlchemyCatalog.tags[id];
        if (tag == null) continue;
        final group = tag.conflictGroup;
        if (group != null && !usedGroups.add(group)) continue;
        selectedTagIds.add(id);
        if (selectedTagIds.length >= maxTags) break;
      }
      selectedTagIds.sort();
      items.add(
        AlchemyItem(
          instanceId:
              'gather_custom_${gatheredAt.microsecondsSinceEpoch}_${index + 1}',
          templateId: 'custom_material',
          quality: quality,
          quantity: 1 + rng.nextInt(3),
          tagIds: selectedTagIds,
          acquiredAt: gatheredAt,
          customName: discovery.name,
          customDescription: discovery.description,
          customCategories: discovery.categories,
          customType: AlchemyItemType.material,
        ),
      );
    }
    return GatherResult(
      node: node,
      items: items,
      gatheredAt: gatheredAt,
      nextAvailableAt: gatheredAt.add(Duration(seconds: node.respawnSeconds)),
    );
  }

  List<String> _inferredTagIds(GatherDiscovery discovery) {
    final text = [
      discovery.name,
      discovery.description,
      ...discovery.categories,
    ].join(' ').toLowerCase();
    final result = <String>{};
    if (RegExp(r'火|热|爆|燃|fire|flame|heat').hasMatch(text)) {
      result.addAll(['fire', 'unstable']);
    }
    if (RegExp(r'水|冰|凉|清|water|ice|cool').hasMatch(text)) {
      result.addAll(['cooling', 'stable']);
    }
    if (RegExp(r'药|草|花|果|恢复|治愈|herb|plant|heal|fruit').hasMatch(text)) {
      result.addAll(['healing', 'durable']);
    }
    if (RegExp(r'矿|石|金属|晶|宝石|ore|stone|metal|crystal|gem').hasMatch(text)) {
      result.addAll(['durable', 'high_price']);
    }
    if (RegExp(r'玻璃|薄|脆|glass|fragile').hasMatch(text)) {
      result.add('fragile');
    }
    if (result.isEmpty) result.addAll(['stable', 'durable', 'cheap']);
    return result.toList(growable: false);
  }

  GatherDrop _takeWeightedDrop(List<GatherDrop> drops, Random random) {
    final totalWeight = drops.fold<int>(
      0,
      (total, drop) => total + max(0, drop.weight),
    );
    if (totalWeight <= 0) throw const FormatException('采集点掉落权重无效');
    var roll = random.nextInt(totalWeight);
    for (var index = 0; index < drops.length; index++) {
      final weight = max(0, drops[index].weight);
      if (roll < weight) return drops.removeAt(index);
      roll -= weight;
    }
    return drops.removeLast();
  }
}
