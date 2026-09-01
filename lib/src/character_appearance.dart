import 'dart:convert';
import 'dart:math';

import 'package:flutter/services.dart';

import 'character_expression.dart';

class CharacterAppearance {
  const CharacterAppearance({
    required this.id,
    required this.label,
    required this.description,
    required this.assetName,
    required this.animated,
    required this.idleAnimations,
  });

  final String id;
  final String label;
  final String description;
  final String assetName;
  final bool animated;
  final List<String> idleAnimations;

  String get previewAsset => 'assets/images/skins/$assetName.png';
  String get assetRoot => 'assets/character/ryza/$assetName';
  String get atlasAsset => '$assetRoot/$assetName.atlas';
  String get skeletonAsset => '$assetRoot/$assetName.skel';
  String get gestureAsset => '$assetRoot/${assetName}_gesture.json';
}

const characterAppearances = <CharacterAppearance>[
  CharacterAppearance(
    id: 'seated_01',
    label: '常服·坐姿',
    description: '原版普通坐姿资源，包含完整的坐姿动作库',
    assetName: 'crf_skn_002_0001_01',
    animated: true,
    idleAnimations: [
      'motion_A_001_idle',
      'motion_A_002_idle',
      'motion_A_003_idle',
      'motion_A_004_idle',
      'motion_A_005_idle',
      'motion_A_006_idle',
      'motion_A_007_idle',
      'motion_A_008_idle',
      'motion_A_022_idle',
      'motion_A_024_idle',
      'motion_A_025_idle',
      'motion_A_026_idle',
      'motion_A_027_idle',
      'motion_A_028_idle',
      'motion_A_029_idle',
      'motion_A_030_idle',
      'motion_A_031_idle',
      'motion_A_032_idle',
      'motion_A_033_idle',
      'motion_A_034_idle',
    ],
  ),
  CharacterAppearance(
    id: 'standing_99',
    label: '常服·站姿',
    description: '原版莱莎3常服站姿资源',
    assetName: 'crf_skn_002_0001_99',
    animated: true,
    idleAnimations: [
      'motion_A_001_idle',
      'motion_A_002_idle',
      'motion_A_003_idle',
      'motion_A_004_idle',
      'motion_A_005_idle',
      'motion_A_006_idle',
      'motion_A_007_idle',
    ],
  ),
  CharacterAppearance(
    id: 'summer_yellow_01',
    label: '夏日泳装·黄色',
    description: '原包服装预览资源；缺少对应 Spine 骨骼与纹理，仅支持静态展示',
    assetName: 'crf_skn_002_0002_01',
    animated: false,
    idleAnimations: [],
  ),
  CharacterAppearance(
    id: 'summer_black_01',
    label: '夏日泳装·黑色',
    description: '原包服装预览资源；缺少对应 Spine 骨骼与纹理，仅支持静态展示',
    assetName: 'crf_skn_002_0003_01',
    animated: false,
    idleAnimations: [],
  ),
  CharacterAppearance(
    id: 'relaxed_shirt_01',
    label: '休闲 T 恤',
    description: '原包服装预览资源；缺少对应 Spine 骨骼与纹理，仅支持静态展示',
    assetName: 'crf_skn_002_0004_01',
    animated: false,
    idleAnimations: [],
  ),
];

const characterOneShotAnimations = <String>[
  'motion_oneshot_D_001_active',
  'motion_oneshot_D_002_active',
  'motion_oneshot_D_003_active',
  'motion_oneshot_D_004_active',
  'motion_oneshot_D_005_active',
  'motion_oneshot_D_006_active',
  'motion_oneshot_D_007_active',
  'motion_oneshot_D_008_active',
  'motion_oneshot_D_009_active',
  'motion_oneshot_D_010_active',
  'motion_oneshot_D_011_active',
  'motion_oneshot_D_012_active',
];

CharacterAppearance characterAppearanceById(String id) {
  return characterAppearances.firstWhere(
    (appearance) => appearance.id == id,
    orElse: () => characterAppearances.first,
  );
}

String motionDisplayName(String animation) {
  final match = RegExp(r'_(\d+)_').firstMatch(animation);
  final number = match?.group(1) ?? animation;
  if (animation.contains('oneshot')) {
    final value = int.tryParse(number) ?? 0;
    if (value <= 2) return '赞同动作 $number';
    if (value <= 8) return '否定动作 $number';
    return '提问动作 $number';
  }
  return '闲置姿势 $number';
}

Future<List<CharacterMotionGroup>> loadCharacterMotionGroups(
  CharacterAppearance appearance,
) async {
  final source = await rootBundle.loadString(appearance.gestureAsset);
  return parseCharacterMotionGroups(source);
}

List<CharacterMotionGroup> parseCharacterMotionGroups(String source) {
  final json = jsonDecode(source) as Map<String, dynamic>;
  final emotionalGesture = json['emotionalGesture'] as Map<String, dynamic>;
  final groups = emotionalGesture['MotionGroups'] as List<dynamic>;
  final weightsByGroup = <String, Map<CharacterExpression, double>>{};
  final profiles = emotionalGesture['EmotionProfilesV4'];
  if (profiles is Map<String, dynamic>) {
    for (final profileEntry in profiles.entries) {
      final expression = characterExpressionFromTag(profileEntry.key);
      final profile = profileEntry.value;
      if (profile is! Map<String, dynamic>) continue;
      final intensityProfiles = profile['intensityProfiles'];
      if (intensityProfiles is! Map<String, dynamic>) continue;
      final normal = intensityProfiles['normal'];
      if (normal is! Map<String, dynamic>) continue;
      Object? rawWeights = normal['armGroupWeights'];
      if (rawWeights == null) {
        final byPose = normal['armGroupWeightsByPoseType'];
        if (byPose is Map<String, dynamic>) rawWeights = byPose[''];
      }
      if (rawWeights is! Map<String, dynamic>) continue;
      for (final weightEntry in rawWeights.entries) {
        final weight = (weightEntry.value as num?)?.toDouble() ?? 0;
        if (weight <= 0) continue;
        weightsByGroup.putIfAbsent(weightEntry.key, () => {})[expression] =
            weight;
      }
    }
  }
  return groups
      .whereType<Map<String, dynamic>>()
      .map(
        (group) => CharacterMotionGroup.fromJson(
          group,
          emotionWeights:
              weightsByGroup[group['GroupId'] as String? ?? ''] ?? const {},
        ),
      )
      .where((group) => group.animation1.isNotEmpty)
      .toList(growable: false);
}

class CharacterMotionGroup {
  const CharacterMotionGroup({
    required this.id,
    required this.label,
    required this.occupancy,
    required this.animation1,
    required this.animation2,
    required this.alpha1,
    required this.alpha2,
    required this.speed1,
    required this.speed2,
    required this.blendTime,
    required this.applicablePoseIds,
    this.emotionWeights = const {},
  });

  final String id;
  final String label;
  final String occupancy;
  final String animation1;
  final String? animation2;
  final double alpha1;
  final double alpha2;
  final double speed1;
  final double speed2;
  final double blendTime;
  final List<String> applicablePoseIds;
  final Map<CharacterExpression, double> emotionWeights;

  bool supportsPose(String? pose) =>
      pose == null ||
      applicablePoseIds.isEmpty ||
      applicablePoseIds.contains(pose);

  List<int> get occupiedTracks => occupancy
      .split('')
      .map(motionTrackForOccupancyLetter)
      .whereType<int>()
      .toList(growable: false);

  factory CharacterMotionGroup.fromJson(
    Map<String, dynamic> json, {
    Map<CharacterExpression, double> emotionWeights = const {},
  }) {
    double number(String key, [double fallback = 1]) =>
        double.tryParse(json[key] as String? ?? '') ?? fallback;

    final second = json['AnimName_2'] as String? ?? '';
    return CharacterMotionGroup(
      id: json['GroupId'] as String? ?? '',
      label: json['Label'] as String? ?? '',
      occupancy: json['OccupancyLetters'] as String? ?? '',
      animation1: json['AnimName_1'] as String? ?? '',
      animation2: second.isEmpty ? null : second,
      alpha1: number('Alpha1'),
      alpha2: number('Alpha2'),
      speed1: number('Speed1'),
      speed2: number('Speed2'),
      blendTime: number('BlendTime', 0.3),
      applicablePoseIds: (json['ApplicablePoseIds'] as String? ?? '')
          .split(',')
          .map((value) => value.trim())
          .where((value) => value.isNotEmpty)
          .toList(growable: false),
      emotionWeights: Map.unmodifiable(emotionWeights),
    );
  }

  double weightFor(CharacterExpression expression) =>
      emotionWeights[expression] ?? 0;
}

CharacterMotionGroup? selectCharacterAmbientMotionGroup({
  required List<CharacterMotionGroup> groups,
  required CharacterExpression expression,
  required String? pose,
  required Set<String> recentGroupIds,
  required Random random,
  required bool allowLargePostureChanges,
  double explorationChance = 0.2,
}) {
  var compatible = groups
      .where(
        (group) =>
            group.supportsPose(pose) &&
            group.occupiedTracks.isNotEmpty &&
            !recentGroupIds.contains(group.id) &&
            (allowLargePostureChanges || !group.occupancy.contains('C')),
      )
      .toList();
  if (compatible.isEmpty && recentGroupIds.isNotEmpty) {
    compatible = groups
        .where(
          (group) =>
              group.supportsPose(pose) &&
              group.occupiedTracks.isNotEmpty &&
              (allowLargePostureChanges || !group.occupancy.contains('C')),
        )
        .toList();
  }
  if (compatible.isEmpty) return null;

  final preferred = compatible
      .where((group) => group.weightFor(expression) > 0)
      .toList();
  final explore = preferred.isEmpty || random.nextDouble() < explorationChance;
  final pool = explore ? compatible : preferred;
  if (explore) return pool[random.nextInt(pool.length)];

  final variantsPerId = <String, int>{};
  for (final group in pool) {
    variantsPerId[group.id] = (variantsPerId[group.id] ?? 0) + 1;
  }
  final total = pool.fold<double>(
    0,
    (sum, group) =>
        sum + group.weightFor(expression) / variantsPerId[group.id]!,
  );
  var target = random.nextDouble() * total;
  for (final group in pool) {
    target -= group.weightFor(expression) / variantsPerId[group.id]!;
    if (target <= 0) return group;
  }
  return pool.last;
}

int? motionTrackForOccupancyLetter(String letter) {
  if (letter.length != 1) return null;
  final code = letter.codeUnitAt(0);
  final first = 'B'.codeUnitAt(0);
  final last = 'J'.codeUnitAt(0);
  if (code < first || code > last) return null;
  return 2 + code - first;
}
