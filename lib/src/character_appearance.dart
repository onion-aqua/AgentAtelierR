import 'dart:convert';
import 'dart:math';

import 'package:flutter/services.dart';

import 'character_expression.dart';
import 'character_idle_behavior.dart';
import 'protected_character_assets.dart';
import 'local_skin_store.dart';

class CharacterAppearance {
  const CharacterAppearance({
    required this.id,
    required this.label,
    required this.description,
    required this.promptDescription,
    required this.assetName,
    required this.animated,
    required this.idleAnimations,
    this.hasPreview = true,
    this.baseAppearanceId,
  });

  final String id;
  final String label;
  final String description;
  final String promptDescription;
  final String assetName;
  final bool animated;
  final List<String> idleAnimations;
  final bool hasPreview;
  final String? baseAppearanceId;
  bool get isStanding => (baseAppearanceId ?? id) == 'standing_99';

  String get previewAsset => 'assets/images/skins/$assetName.png';
  String get assetRoot => 'assets/character/ryza/$assetName';
  String get atlasAsset => '$assetRoot/$assetName.atlas';
  String get skeletonAsset => '$assetRoot/$assetName.skel';
  String get gestureAsset => '$assetRoot/${assetName}_gesture.json';
}

final characterAppearances = <CharacterAppearance>[
  CharacterAppearance(
    id: 'seated_01',
    label: '常服·坐姿',
    description: '原版普通坐姿资源，包含完整的坐姿动作库',
    promptDescription: '莱莎穿着白色无袖上衣、浅蓝领饰、棕色合身皮革马甲与红色短裤，戴黑色兔耳形发带和白色花朵发饰；当前是坐姿。',
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
    promptDescription: '莱莎穿着白色上衣、棕色合身皮革马甲和红色短裤，肩上披着黄白色短外套，腰间系有工具腰带与炼金小瓶；当前是站姿。',
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
    description: '完整 Spine 服装与动作资源',
    promptDescription: '莱莎穿着黄白配色的花纹荷叶边泳装，上身带肩部褶边，下身搭配黄色褶边围裙式泳裙与青绿色细绳装饰；当前是坐姿。',
    assetName: 'crf_skn_002_0002_01',
    animated: true,
    idleAnimations: [
      'motion_A_001_idle',
      'motion_A_002_idle',
      'motion_A_003_idle',
    ],
  ),
  CharacterAppearance(
    id: 'summer_black_01',
    label: '夏日泳装·黑色',
    description: '完整 Spine 服装与动作资源',
    promptDescription: '莱莎穿着黑白配色的荷叶边泳装，下身搭配黑色褶边围裙式泳裙与青绿色细绳装饰；当前是坐姿。',
    assetName: 'crf_skn_002_0003_01',
    animated: true,
    idleAnimations: [
      'motion_A_001_idle',
      'motion_A_002_idle',
      'motion_A_003_idle',
    ],
  ),
  CharacterAppearance(
    id: 'relaxed_shirt_01',
    label: '休闲 T 恤',
    description: '完整 Spine 服装与动作资源',
    promptDescription: '莱莎穿着宽松的白色短袖长款 T 恤，袖口有黑色包边，胸前印着蓝色可爱图案；当前是坐姿。',
    assetName: 'crf_skn_002_0004_01',
    animated: true,
    idleAnimations: [
      'motion_A_001_idle',
      'motion_A_002_idle',
      'motion_A_003_idle',
    ],
  ),
  CharacterAppearance(
    id: 'crf_skn_002_0005_01',
    label: '夏日泳装·蓝白短裤',
    description: '完整 Spine 服装与动作资源',
    promptDescription: '莱莎穿着蓝白配色、金色滚边与红色细带的泳装上衣，搭配深蓝色短裤和浅蓝色腰带；头顶架着心形太阳镜，手腕戴有蓝色手镯、金色细环和花朵饰品；当前是坐姿。服装细节来自贴图，名称为应用内描述名，不是已确认的官方名称。',
    assetName: 'crf_skn_002_0005_01',
    animated: true,
    idleAnimations: [
      'motion_A_001_idle',
      'motion_A_002_idle',
      'motion_A_003_idle',
    ],
  ),
];

void registerLocalSkinAppearances() {
  for (final record in LocalSkinStore.instance.skins) {
    if (characterAppearances.any(
      (appearance) => appearance.id == record['id'],
    )) {
      continue;
    }
    final base = characterAppearances
        .where((appearance) => appearance.assetName == record['base'])
        .firstOrNull;
    characterAppearances.add(
      CharacterAppearance(
        id: record['id']!,
        label: record['label']!,
        description: '本地导入皮肤',
        promptDescription: '当前使用用户导入的皮肤，未提供具体外观描述，不要猜测服装细节。',
        assetName: record['id']!,
        animated: true,
        hasPreview: false,
        baseAppearanceId: base?.id,
        idleAnimations: base?.idleAnimations ?? const ['motion_A_001_idle'],
      ),
    );
  }
}

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
  CharacterAppearance appearance, {
  AssetBundle? bundle,
}) async {
  final assets =
      bundle ?? await ProtectedCharacterAssets.bundleFor(appearance.assetName);
  final source = await assets.loadString(appearance.gestureAsset);
  return parseCharacterMotionGroups(source);
}

List<CharacterMotionGroup> parseCharacterMotionGroups(String source) {
  final json = jsonDecode(source) as Map<String, dynamic>;
  final emotionalGesture = json['emotionalGesture'] as Map<String, dynamic>;
  final groups = emotionalGesture['MotionGroups'] as List<dynamic>;
  final weightsByGroup = <String, Map<CharacterExpression, double>>{};
  final weightsByPoseType =
      <String, Map<CharacterExpression, Map<String, double>>>{};
  double weight(Object? value) =>
      value is num && value.isFinite && value > 0 ? value.toDouble() : 0;
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
      final byPose = normal['armGroupWeightsByPoseType'];
      if (byPose is Map<String, dynamic>) {
        for (final poseEntry in byPose.entries) {
          final poseWeights = poseEntry.value;
          if (poseEntry.key.isEmpty || poseWeights is! Map<String, dynamic>) {
            continue;
          }
          weightsByPoseType.putIfAbsent(poseEntry.key, () => {})[expression] = {
            for (final entry in poseWeights.entries)
              entry.key: weight(entry.value),
          };
        }
      }
      Object? rawWeights = normal['armGroupWeights'];
      if (rawWeights == null) {
        if (byPose is Map<String, dynamic>) rawWeights = byPose[''];
      }
      if (rawWeights is! Map<String, dynamic>) continue;
      for (final weightEntry in rawWeights.entries) {
        final value = weight(weightEntry.value);
        if (value <= 0) continue;
        weightsByGroup.putIfAbsent(weightEntry.key, () => {})[expression] =
            value;
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
          emotionWeightsByPoseType: {
            for (final poseEntry in weightsByPoseType.entries)
              poseEntry.key: {
                for (final expressionEntry in poseEntry.value.entries)
                  expressionEntry.key:
                      expressionEntry.value[group['GroupId']] ?? 0,
              },
          },
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
    this.applicableSittingIds = const [],
    this.emotionWeights = const {},
    this.emotionWeightsByPoseType = const {},
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
  final List<String> applicableSittingIds;
  final Map<CharacterExpression, double> emotionWeights;
  final Map<String, Map<CharacterExpression, double>> emotionWeightsByPoseType;

  bool supportsPose(String? pose) =>
      pose == null ||
      applicablePoseIds.isEmpty ||
      applicablePoseIds.contains(pose);

  bool supportsSitting([String sittingId = 'sitting_normal']) =>
      applicableSittingIds.isEmpty || applicableSittingIds.contains(sittingId);

  List<int> get occupiedTracks => occupancy
      .split('')
      .map(motionTrackForOccupancyLetter)
      .whereType<int>()
      .toList(growable: false);

  factory CharacterMotionGroup.fromJson(
    Map<String, dynamic> json, {
    Map<CharacterExpression, double> emotionWeights = const {},
    Map<String, Map<CharacterExpression, double>> emotionWeightsByPoseType =
        const {},
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
      applicableSittingIds: (json['ApplicableSittingIDs'] as String? ?? '')
          .split(',')
          .map((value) => value.trim())
          .where((value) => value.isNotEmpty)
          .toList(growable: false),
      emotionWeights: Map.unmodifiable(emotionWeights),
      emotionWeightsByPoseType: Map.unmodifiable({
        for (final entry in emotionWeightsByPoseType.entries)
          entry.key: Map<CharacterExpression, double>.unmodifiable(entry.value),
      }),
    );
  }

  double weightFor(CharacterExpression expression, {String? poseType}) =>
      emotionWeightsByPoseType[poseType]?[expression] ??
      emotionWeights[expression] ??
      0;

  CharacterExpression pairedExpression(CharacterExpression current) {
    // Preserve a compatible face; otherwise use the strongest authored weight.
    if (weightFor(current) > 0) return current;
    var best = current;
    var weight = 0.0;
    for (final expression in CharacterExpression.values) {
      final candidate = weightFor(expression);
      if (candidate > weight) {
        weight = candidate;
        best = expression;
      }
    }
    return best;
  }
}

CharacterMotionGroup? selectCharacterAmbientMotionGroup({
  required List<CharacterMotionGroup> groups,
  required CharacterExpression expression,
  required String? pose,
  required Set<String> recentGroupIds,
  required Random random,
  required bool allowLargePostureChanges,
  bool allowSubtleLegChanges = false,
  double explorationChance = 0.2,
  bool authoredOnly = false,
  String sittingId = 'sitting_normal',
  String? poseType,
  Map<String, double> groupWeights = const {},
}) {
  double weight(CharacterMotionGroup group) =>
      groupWeights[group.id] ?? group.weightFor(expression, poseType: poseType);
  bool allowed(CharacterMotionGroup group) =>
      group.supportsPose(pose) &&
      group.supportsSitting(sittingId) &&
      group.occupiedTracks.isNotEmpty &&
      (allowLargePostureChanges ||
          !group.occupancy.contains('C') ||
          (allowSubtleLegChanges &&
              isSpeakingLegMotion(group.occupancy, group.id))) &&
      (!authoredOnly || weight(group) > 0);
  var compatible = groups
      .where((group) => allowed(group) && !recentGroupIds.contains(group.id))
      .toList();
  if (compatible.isEmpty && recentGroupIds.isNotEmpty) {
    compatible = groups.where(allowed).toList();
  }
  if (compatible.isEmpty) return null;

  final preferred = compatible.where((group) => weight(group) > 0).toList();
  final explore =
      !authoredOnly &&
      (preferred.isEmpty || random.nextDouble() < explorationChance);
  final pool = explore ? compatible : preferred;
  if (explore) return pool[random.nextInt(pool.length)];

  final variantsPerId = <String, int>{};
  for (final group in pool) {
    variantsPerId[group.id] = (variantsPerId[group.id] ?? 0) + 1;
  }
  final total = pool.fold<double>(
    0,
    (sum, group) => sum + weight(group) / variantsPerId[group.id]!,
  );
  var target = random.nextDouble() * total;
  for (final group in pool) {
    target -= weight(group) / variantsPerId[group.id]!;
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
