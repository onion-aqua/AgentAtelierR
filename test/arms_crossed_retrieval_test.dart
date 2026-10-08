import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:spine_flutter/spine_flutter.dart';
import 'package:ryza_chat_mvp/src/character_appearance.dart';
import 'package:ryza_chat_mvp/src/character_motion_semantics.dart';
import 'package:ryza_chat_mvp/src/motion_candidate_search.dart';
import 'package:ryza_chat_mvp/src/motion_recipe.dart';

const _armsIds = {'grp_b_05', 'grp_fg_023', 'grp_fg_002'};
const _screenshotQuery =
    '请在胸前抱起双臂\n'
    '旁白：莱莎听话地挺直身子，准备在胸前抱起双臂，带着一点得意的笑意看向你。\n'
    '莱莎：こんな感じかな？ちょっと格好よく見えるでしょ、相棒。';
const _queries = [
  _screenshotQuery,
  '胸前抱起双臂',
  '胸前交叉抱臂',
  '双臂交叉',
  '抱胸',
  '环胸',
  '揣手（抱臂）',
  '腕を組んでください',
  '腕組み',
  'Please cross your arms in front of your chest',
  'fold your arms',
];

List<CharacterMotionGroup> _groups(String skin) => parseCharacterMotionGroups(
  File('assets/character/ryza/$skin/${skin}_gesture.json').readAsStringSync(),
);

Map<String, String> _catalogue({
  required String skin,
  required String pose,
  required Set<String> animations,
  required List<CharacterMotionGroup> groups,
  required List<MotionRecipe> recipes,
  required Map<String, String> descriptions,
  required Map<String, String> recipeDescriptions,
}) {
  final standing = skin.endsWith('_99');
  // Use the public resource guards and real native animation inventory. No
  // missing arm track, incompatible posture, or unknown generated layer is
  // inserted merely because its semantic name matches the requested gesture.
  return {
    for (final group in groups)
      if (group.supportsPose(pose) &&
          group.supportsSitting('sitting_normal') &&
          group.occupiedTracks.isNotEmpty &&
          animations.contains(group.animation1) &&
          (group.animation2 == null ||
              (group.occupiedTracks.length > 1 &&
                  animations.contains(group.animation2))) &&
          !group.label.contains('使わない') &&
          !group.animation1.contains('_ignore') &&
          !(group.animation2?.contains('_ignore') ?? false) &&
          (group.alpha1 > 0 || (group.animation2 != null && group.alpha2 > 0)))
        group.id: descriptions[group.id]!,
    for (final recipe in recipes)
      if (recipe.available(
            animations,
            pose,
            'sitting_normal',
            appearanceId: standing ? 'standing_99' : 'seated_01',
            appearanceAssetName: skin,
            isStanding: standing,
          ) &&
          !(recipe.tags.contains('generated') &&
              recipeDescriptions[recipe.id]!.contains('语义未标注')))
        recipe.id: recipeDescriptions[recipe.id]!,
  };
}

Future<void> _expectNativeArmsInBothWindows(
  Map<String, String> catalogue,
  Set<String> eligible,
) async {
  await prepareMotionCandidateIndex(catalogue);
  for (final query in _queries) {
    for (final limit in [16, 48]) {
      final result = selectMotionCandidates(
        catalogue,
        query,
        limit: limit,
        // A repeated explicit request must remain discoverable, even when the
        // recently played gesture receives the ordinary diversity penalty.
        recentKeys: eligible,
      );
      expect(result.length, lessThanOrEqualTo(limit));
      expect(
        result.keys.where(eligible.contains),
        isNotEmpty,
        reason: 'query=$query, limit=$limit, eligible=$eligible',
      );
      expect(result.keys.every(catalogue.containsKey), isTrue);
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final nativeEnabled = Platform.environment['AAR_SPINE_NATIVE_TEST'] == '1';

  test(
    'arm aliases retrieve only supplied resources, never fabricate tracks',
    () {
      final groups = _groups('crf_skn_002_0001_01');
      final legs = groups.firstWhere((group) => group.id == 'grp_c_01');
      final catalogue = {legs.id: characterMotionPromptDescription(legs)};
      for (final query in _queries) {
        final selected = selectMotionCandidates(catalogue, query);
        expect(selected.keys.toSet(), {legs.id});
        expect(selected.keys.where(_armsIds.contains), isEmpty);
      }
    },
  );

  for (final configuration in [
    (
      skin: 'crf_skn_002_0001_01',
      pose: 'motion_A_001_idle',
      eligible: {'grp_b_05', 'grp_fg_023'},
    ),
    (
      skin: 'crf_skn_002_0001_01',
      pose: 'motion_A_003_idle',
      eligible: {'grp_fg_023'},
    ),
    (
      skin: 'crf_skn_002_0001_99',
      pose: 'motion_A_001_idle',
      eligible: {'grp_fg_002'},
    ),
  ]) {
    final root =
        'assets/character/ryza/${configuration.skin}/${configuration.skin}';
    test(
      'native crossed arms stay retrievable for ${configuration.skin}/${configuration.pose}',
      () async {
        await initSpineFlutter();
        final drawable = await SkeletonDrawable.fromFile(
          '$root.atlas',
          '$root.skel',
        );
        try {
          final animations = drawable.skeletonData
              .getAnimations()
              .map((animation) => animation.getName())
              .toSet();
          final groups = _groups(configuration.skin);
          final recipes = MotionRecipe.merge([
            MotionRecipe.parse(
              File('assets/data/motion_recipes.json').readAsStringSync(),
            ),
            MotionRecipe.parse(
              File('assets/data/motion_recipes_extra.json').readAsStringSync(),
            ),
          ]);
          expect(recipes, hasLength(38190));
          final descriptions = {
            for (final group in groups)
              group.id: characterMotionPromptDescription(group),
          };
          final recipeDescriptions = motionRecipePromptDescriptions((
            recipes: recipes,
            groups: groups,
            groupDescriptions: descriptions,
          ));
          final catalogue = _catalogue(
            skin: configuration.skin,
            pose: configuration.pose,
            animations: animations,
            groups: groups,
            recipes: recipes,
            descriptions: descriptions,
            recipeDescriptions: recipeDescriptions,
          );
          expect(
            catalogue.keys.where(_armsIds.contains).toSet(),
            configuration.eligible,
          );
          await _expectNativeArmsInBothWindows(
            catalogue,
            configuration.eligible,
          );

          // Stress the same selector with 38k repeated chest-area combinations.
          // These index-only copies use real safe non-crossing semantics; they
          // are not played and do not claim to be 38k independent animations.
          final decoy = catalogue.containsKey('grp_b_07')
              ? catalogue['grp_b_07']!
              : catalogue['grp_fg_000'] ?? '双手自然放置';
          final crowdedCatalogue = {
            ...catalogue,
            for (var i = 0; i < 38000; i++)
              'grp_recipe_pressure_$i': '$decoy；身体挺直，胸前手位，自信回应；occupancy=FG',
          };
          await _expectNativeArmsInBothWindows(
            crowdedCatalogue,
            configuration.eligible,
          );

          final missingAnimations = {...animations}
            ..removeAll(
              groups
                  .where((group) => _armsIds.contains(group.id))
                  .expand(
                    (group) => <String>[
                      group.animation1,
                      ...group.animation2 == null
                          ? const []
                          : [group.animation2!],
                    ],
                  ),
            );
          final missingCatalogue = _catalogue(
            skin: configuration.skin,
            pose: configuration.pose,
            animations: missingAnimations,
            groups: groups,
            recipes: recipes,
            descriptions: descriptions,
            recipeDescriptions: recipeDescriptions,
          );
          expect(missingCatalogue.keys.where(_armsIds.contains), isEmpty);
          for (final limit in [16, 48]) {
            final selected = selectMotionCandidates(
              missingCatalogue,
              _screenshotQuery,
              limit: limit,
            );
            expect(selected.keys.where(_armsIds.contains), isEmpty);
            expect(selected.keys.every(missingCatalogue.containsKey), isTrue);
          }
        } finally {
          drawable.dispose();
        }
      },
      skip: !nativeEnabled || !File('$root.skel').existsSync()
          ? 'Set AAR_SPINE_NATIVE_TEST=1 with the Spine native DLL on PATH'
          : false,
      timeout: const Timeout(Duration(minutes: 2)),
    );
  }
}
