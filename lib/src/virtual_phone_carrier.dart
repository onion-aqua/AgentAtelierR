import 'dart:math';

import 'package:flutter/foundation.dart';

import 'character_runtime_profile.dart';
import 'world_travel_catalog.dart';

/// A fictional carrier chosen once for a game, independent of real networking.
@immutable
class VirtualPhoneCarrier {
  const VirtualPhoneCarrier({required this.region, required this.suffix});

  static const suffixes = ['移动', '电信', '联通'];
  static const regions = ['库肯岛', '克莱利亚', '内米德', '异界', '王都'];
  static const _areaRegions = {
    'area_01': '库肯岛',
    'area_02': '克莱利亚',
    'area_03': '内米德',
    'area_04': '异界',
    'area_05': '王都',
  };

  final String region;
  final String suffix;

  String get name => '$region$suffix';

  factory VirtualPhoneCarrier.create({
    required String region,
    Random? random,
  }) => VirtualPhoneCarrier(
    region: regions.contains(region) ? region : '异界',
    suffix: suffixes[(random ?? Random()).nextInt(suffixes.length)],
  );

  factory VirtualPhoneCarrier.fromJson(Object? value) {
    if (value is! Map ||
        !regions.contains(value['region']) ||
        !suffixes.contains(value['suffix'])) {
      throw const FormatException('虚拟手机运营商存档数据无效');
    }
    return VirtualPhoneCarrier(
      region: value['region'] as String,
      suffix: value['suffix'] as String,
    );
  }

  /// Stable migration makes the same old save agree across validation, loading,
  /// reimport and export before its newly added metadata has been written back.
  factory VirtualPhoneCarrier.migrate({
    required String region,
    required String seed,
  }) {
    var hash = 2166136261;
    for (final value in seed.codeUnits) {
      hash = ((hash ^ value) * 16777619) & 0xffffffff;
    }
    return VirtualPhoneCarrier(
      region: regions.contains(region) ? region : '异界',
      suffix: suffixes[hash % suffixes.length],
    );
  }

  Map<String, String> toJson() => {'region': region, 'suffix': suffix};

  static String regionForLocation({
    required WorldTravelCatalog catalog,
    required String characterId,
    required String areaId,
    required String stageId,
  }) {
    if (characterId == CharacterRuntimeIds.sophie) return '异界';
    // Resolve the actual catalog entry first; no guesses from stage substrings.
    final destination = catalog.byStageId(stageId);
    return _areaRegions[destination?.areaId ?? areaId] ?? '异界';
  }
}
