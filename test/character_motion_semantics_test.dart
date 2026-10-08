import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ryza_chat_mvp/src/character_appearance.dart';
import 'package:ryza_chat_mvp/src/character_motion_semantics.dart';
import 'package:ryza_chat_mvp/src/motion_recipe.dart';

List<CharacterMotionGroup> _resourceGroups(String appearance) =>
    parseCharacterMotionGroups(
      File('assets/character/ryza/$appearance/${appearance}_gesture.json')
          .readAsStringSync(),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final seated = _resourceGroups('crf_skn_002_0001_01');
  final standing = _resourceGroups('crf_skn_002_0001_99');

  test('the authored B007 pose exposes chest-crossed arm semantics', () {
    final group = seated.firstWhere((group) => group.id == 'grp_b_05');
    expect(group.animation1, 'motion_add_B_007_active');
    expect(group.label, contains('腕組み'));

    final description = characterMotionPromptDescription(group);
    expect(description, contains('双臂在胸前交叉抱臂'));
    expect(description, contains('抱胸/环胸'));
    expect(description, contains('自信回应'));
    expect(description, contains('资源标签：${group.label}'));
  });

  test('the authored two-hand F049 G049 group describes the full pose', () {
    final group = seated.firstWhere((group) => group.id == 'grp_fg_023');
    expect(group.animation1, 'motion_add_F_049_active');
    expect(group.animation2, 'motion_add_G_049_active');
    expect(group.occupancy, 'FG');

    final description = characterMotionPromptDescription(group);
    expect(description, contains('双臂在胸前交叉抱臂组合'));
    expect(description, contains('抱胸/环胸'));
  });

  test(
    'standing arms keep their posture and actual standing animation pair',
    () {
      final group = standing.firstWhere((group) => group.id == 'grp_fg_002');
      expect(group.animation1, 'motion_add_F_003_active');
      expect(group.animation2, 'motion_add_G_003_active');
      expect(
        characterMotionPromptDescription(group),
        startsWith('站姿双臂在胸前交叉抱臂'),
      );
    },
  );

  test('hands at the chest do not gain crossed-arm semantics', () {
    final group = seated.firstWhere((group) => group.id == 'grp_b_07');
    expect(group.animation1, 'motion_add_B_009_active');
    final semantic = characterMotionPromptDescription(group)
        .split('；资源标签')
        .first;
    expect(semantic, '双手放在胸前，真诚回应');
    expect(semantic, isNot(contains('交叉')));
    expect(semantic, isNot(contains('抱臂')));
  });

  test('an actual generated three-layer pose stays fully described under the planner budget', () {
    final recipes = MotionRecipe.parse(
      File('assets/data/motion_recipes_extra.json').readAsStringSync(),
    );
    const requiredLayers = {
      'motion_add_E_005_active',
      'motion_add_F_049_active',
      'motion_add_G_049_active',
    };
    final recipe = recipes.firstWhere(
      (recipe) =>
          recipe.base == 'motion_A_001_idle' &&
          recipe.stages.length == 1 &&
          recipe.stages.single.length == 3 &&
          recipe.stages.single
              .map((layer) => layer.name)
              .toSet()
              .containsAll(requiredLayers),
    );
    final descriptions = motionRecipePromptDescriptions((
      recipes: [recipe],
      groups: seated,
      groupDescriptions: {
        for (final group in seated)
          group.id: characterMotionPromptDescription(group),
      },
    ));

    final description = descriptions[recipe.id]!;
    expect(description, contains('双臂在胸前交叉抱臂组合'));
    expect(description, contains('身体向前倾听'));
    expect(description, contains('occupancy=EFG'));
    expect(description, isNot(contains('语义未标注')));
    expect(description.length, lessThan(220));
  });

  test(
    'unknown group IDs keep an unknown semantic even with a familiar label',
    () {
      final group = CharacterMotionGroup.fromJson({
        'GroupId': 'grp_unrecognised',
        'Label': '腕組み',
        'OccupancyLetters': 'B',
        'AnimName_1': 'motion_add_B_007_active',
      });
      final description = characterMotionPromptDescription(group);
      expect(description, startsWith('资源标签所描述的动作；不要推断未写明的姿势'));
      expect(description, endsWith('资源标签：腕組み。'));
      expect(description, isNot(contains('双臂在胸前交叉')));
    },
  );
}
