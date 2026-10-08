import 'dart:convert';

import 'character_appearance.dart';

/// Join generated layers to known authored semantics without inventing a pose
/// from an animation number. This is pure data work and can run in an isolate.
Map<String, String> motionRecipePromptDescriptions(
  ({
    List<MotionRecipe> recipes,
    List<CharacterMotionGroup> groups,
    Map<String, String> groupDescriptions,
  })
  data,
) {
  final byAnimation = <String, List<CharacterMotionGroup>>{};
  for (final group in data.groups) {
    if (group.alpha1 <= 0 || group.label.contains('使わない')) continue;
    byAnimation.putIfAbsent(group.animation1, () => []).add(group);
  }
  final stageDescriptions = <String, String>{};
  return {
    for (final recipe in data.recipes)
      recipe.id: recipe.tags.contains('generated')
          ? '${recipe.stages.map((stage) {
              final names = stage.map((layer) => layer.name).toSet();
              final signature = names.toList()..sort();
              return stageDescriptions.putIfAbsent('${recipe.base}|${signature.join('|')}', () {
                final semantics = <String>{};
                final covered = <String>{};
                for (final name in names) {
                  for (final group in byAnimation[name] ?? const <CharacterMotionGroup>[]) {
                    if (!group.supportsPose(recipe.base) || !group.supportsSitting('sitting_normal') || (group.animation2 != null && (!names.contains(group.animation2) || group.alpha2 <= 0))) continue;
                    final text = (data.groupDescriptions[group.id] ?? '').split('；资源标签').first;
                    if (text.isNotEmpty && !text.startsWith('资源标签所描述')) {
                      semantics.add(text);
                      covered.add(group.animation1);
                      if (group.animation2 != null) covered.add(group.animation2!);
                    }
                  }
                }
                final tracks = stage.map((layer) => layer.region).join('');
                return '${semantics.join('；')}${covered.containsAll(names) ? '' : '；附加动作语义未标注，不承诺精准动作'}；occupancy=$tracks';
              });
            }).join(' → ')}；${recipe.stages.length}个阶段，脸部独立控制'
          : '${recipe.name}：${recipe.description}；${recipe.stages.length}个阶段，脸部独立控制',
  };
}

class MotionRecipeLayer {
  MotionRecipeLayer(Map<String, dynamic> data)
    : name = data['name'] as String,
      region = data['region'] as String,
      alpha = (data['alpha'] as num).toDouble(),
      speed = (data['speed'] as num).toDouble();
  final String name, region;
  final double alpha, speed;
  int get track => region == 'D' ? 1 : motionTrackForOccupancyLetter(region)!;
}

class MotionRecipe {
  MotionRecipe(Map<String, dynamic> data)
    : id = data['id'] as String,
      name = data['name'] as String,
      description = data['description'] as String,
      base = data['base'] as String,
      category = _stringValue(data['category']),
      posture = _stringValue(data['posture']),
      tags = _stringList(data['tags']),
      skins = _stringList(data['skins']),
      skinOverrides = _mapValue(data['skinOverrides']),
      stages = (data['stages'] as List)
          .map(
            (stage) => (stage as List)
                .map(
                  (layer) => MotionRecipeLayer(
                    Map<String, dynamic>.from(layer as Map),
                  ),
                )
                .toList(),
          )
          .toList();
  final String id, name, description, base;

  /// Optional semantic metadata used by the planner and catalogue UI.
  ///
  /// Older recipe files do not contain these keys, so they intentionally
  /// default to an empty value. `skinOverrides` remains JSON-shaped because
  /// recipe producers may use either a per-skin animation map or a richer
  /// object containing replacement stages.
  final String category;
  final String posture;
  final List<String> tags;
  final List<String> skins;
  final Map<String, dynamic> skinOverrides;
  final List<List<MotionRecipeLayer>> stages;
  bool available(
    Set<String> animations,
    String? pose,
    String sitting, {
    String? appearanceId,
    String? baseAppearanceId,
    String? appearanceAssetName,
    bool? isStanding,
  }) =>
      pose == base &&
      sitting != 'sitting_agura' &&
      supportsAppearance(
        appearanceId: appearanceId,
        baseAppearanceId: baseAppearanceId,
        appearanceAssetName: appearanceAssetName,
        isStanding: isStanding,
      ) &&
      stages.isNotEmpty &&
      stages.every(
        (stage) =>
            _stageSafe(stage) &&
            stage.every(
              (layer) =>
                  animations.contains(layer.name) &&
                  layer.alpha > 0 &&
                  layer.alpha <= 1 &&
                  layer.speed > 0 &&
                  layer.speed.isFinite,
            ),
      );

  /// Runtime guard matching the generator's occupancy rules. This keeps a
  /// stale or hand-edited catalogue from releasing a leg/arm track into a
  /// conflicting stage even when its animation names happen to exist.
  static bool _stageSafe(List<MotionRecipeLayer> stage) {
    if (stage.isEmpty) return false;
    final tracks = stage.map((layer) => layer.track).toSet();
    if (tracks.length != stage.length) return false;
    final regions = stage.map((layer) => layer.region).toSet();
    if (regions.contains('D') && stage.length != 1) return false;
    if (regions.contains('B') &&
        (regions.contains('F') || regions.contains('G'))) {
      return false;
    }
    return true;
  }

  /// Checks optional posture and skin metadata without affecting legacy
  /// recipes. Unknown posture labels are treated as descriptive metadata so a
  /// future catalogue can be shipped before the runtime learns its label.
  bool supportsAppearance({
    String? appearanceId,
    String? baseAppearanceId,
    String? appearanceAssetName,
    bool? isStanding,
  }) {
    final normalizedPosture = posture.trim().toLowerCase();
    final standing =
        isStanding ??
        (appearanceId?.toLowerCase().contains('standing') ?? false);
    final postureMatches = switch (normalizedPosture) {
      '' || 'any' || 'all' || 'universal' || '通用' => true,
      'standing' || 'stand' || '站' || '站姿' => standing,
      'seated' || 'sitting' || 'sit' || '坐' || '坐姿' => !standing,
      _ => true,
    };
    if (!postureMatches) return false;
    if (skins.isEmpty) return true;
    final candidates = <String>{};
    if (appearanceId != null) candidates.add(appearanceId);
    if (baseAppearanceId != null) candidates.add(baseAppearanceId);
    if (appearanceAssetName != null) candidates.add(appearanceAssetName);
    if (candidates.isEmpty) return true;
    return skins.any((skin) {
      final normalized = skin.trim().toLowerCase();
      return normalized.isEmpty ||
          normalized == 'any' ||
          normalized == 'all' ||
          normalized == 'universal' ||
          (normalized == 'standing' ||
                  normalized == 'stand' ||
                  normalized == '站' ||
                  normalized == '站姿') &&
              standing ||
          (normalized == 'seated' ||
                  normalized == 'sitting' ||
                  normalized == 'sit' ||
                  normalized == '坐' ||
                  normalized == '坐姿') &&
              !standing ||
          candidates.any((candidate) => candidate.toLowerCase() == normalized);
    });
  }

  static List<MotionRecipe> parse(String source) =>
      ((jsonDecode(source) as Map)['recipes'] as List)
          .map((data) => MotionRecipe(Map<String, dynamic>.from(data as Map)))
          .toList();

  /// Merges catalogues while preserving source order and the first recipe for
  /// a given id. This lets an optional extension file add recipes without
  /// accidentally replacing a built-in recipe when ids overlap.
  static List<MotionRecipe> merge(Iterable<Iterable<MotionRecipe>> catalogues) {
    final merged = <MotionRecipe>[];
    final seen = <String>{};
    for (final catalogue in catalogues) {
      for (final recipe in catalogue) {
        if (seen.add(recipe.id)) merged.add(recipe);
      }
    }
    return merged;
  }

  static String _stringValue(Object? value) =>
      value is String ? value.trim() : '';

  static List<String> _stringList(Object? value) {
    if (value is! List) return const [];
    return value
        .whereType<String>()
        .map((item) => item.trim())
        .where((item) => item.isNotEmpty)
        .toSet()
        .toList(growable: false);
  }

  static Map<String, dynamic> _mapValue(Object? value) {
    if (value is! Map) return const {};
    return Map<String, dynamic>.fromEntries(
      value.entries
          .where((entry) => entry.key is String)
          .map((entry) => MapEntry(entry.key as String, entry.value)),
    );
  }
}
