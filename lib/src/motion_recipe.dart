import 'dart:convert';

import 'character_appearance.dart';

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
  final List<List<MotionRecipeLayer>> stages;
  bool available(Set<String> animations, String? pose, String sitting) =>
      pose == base &&
      sitting != 'sitting_agura' &&
      stages.isNotEmpty &&
      stages.every(
        (stage) =>
            stage.isNotEmpty &&
            stage.every(
              (layer) =>
                  animations.contains(layer.name) &&
                  layer.alpha > 0 &&
                  layer.alpha <= 1 &&
                  layer.speed > 0 &&
                  layer.speed.isFinite,
            ),
      );
  static List<MotionRecipe> parse(String source) =>
      ((jsonDecode(source) as Map)['recipes'] as List)
          .map((data) => MotionRecipe(Map<String, dynamic>.from(data as Map)))
          .toList();
}
