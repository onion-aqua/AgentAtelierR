import 'package:flutter_test/flutter_test.dart';
import 'package:ryza_chat_mvp/src/character_appearance.dart';
import 'package:ryza_chat_mvp/src/motion_candidate_search.dart';
import 'package:ryza_chat_mvp/src/motion_recipe.dart';

const _base = 'motion_A_001_idle';
const _left = 'motion_add_F_001_active';
const _right = 'motion_add_G_001_active';
const _body = 'motion_add_E_001_active';
const _unknown = 'motion_add_C_999_active';

CharacterMotionGroup _group({
  required String id,
  required String first,
  String? second,
  double secondAlpha = 1,
}) => CharacterMotionGroup(
  id: id,
  label: '已知演出',
  occupancy: second == null ? 'E' : 'FG',
  animation1: first,
  animation2: second,
  alpha1: 1,
  alpha2: secondAlpha,
  speed1: 1,
  speed2: 1,
  blendTime: 0.3,
  applicablePoseIds: const [_base],
);

MotionRecipe _recipe(String id, List<List<String>> stages) => MotionRecipe({
  'id': id,
  'name': '生成组合',
  'description': '技术描述不应充当动作语义',
  'base': _base,
  'tags': ['generated'],
  'stages': [
    for (final stage in stages)
      [
        for (final name in stage)
          {
            'name': name,
            'region': name == _left
                ? 'F'
                : name == _right
                ? 'G'
                : name == _body
                ? 'E'
                : 'C',
            'alpha': 1,
            'speed': 1,
          },
      ],
  ],
});

void main() {
  final dualHand = _group(id: 'grp_fg_dual', first: _left, second: _right);

  test(
    'dual-hand semantics require both authored animations in the same stage',
    () {
      final descriptions = motionRecipePromptDescriptions((
        recipes: [
          _recipe('grp_recipe_left', [
            [_left],
          ]),
          _recipe('grp_recipe_right', [
            [_right],
          ]),
          _recipe('grp_recipe_split', [
            [_left],
            [_right],
          ]),
          _recipe('grp_recipe_complete', [
            [_left, _right],
          ]),
        ],
        groups: [dualHand],
        groupDescriptions: const {'grp_fg_dual': '双手拍手；资源标签：已审核双手演出'},
      ));

      for (final id in [
        'grp_recipe_left',
        'grp_recipe_right',
        'grp_recipe_split',
      ]) {
        expect(descriptions[id], contains('语义未标注'));
        expect(descriptions[id], isNot(contains('双手拍手')));
      }
      expect(descriptions['grp_recipe_complete'], contains('双手拍手'));
      expect(descriptions['grp_recipe_complete'], isNot(contains('语义未标注')));
    },
  );

  test('partly known stages remain marked as unlabelled despite a known dual-hand action', () {
    final descriptions = motionRecipePromptDescriptions((
      recipes: [
        _recipe('grp_recipe_partial', [
          [_left, _right, _unknown],
        ]),
      ],
      groups: [dualHand],
      groupDescriptions: const {'grp_fg_dual': '双手拍手'},
    ));

    expect(descriptions['grp_recipe_partial'], contains('双手拍手'));
    expect(descriptions['grp_recipe_partial'], contains('语义未标注'));
  });

  test('disabled second hand does not make a dual-hand recipe semantically complete', () {
    final descriptions = motionRecipePromptDescriptions((
      recipes: [
        _recipe('grp_recipe_disabled', [
          [_left, _right],
        ]),
      ],
      groups: [
        _group(
          id: 'grp_fg_disabled',
          first: _left,
          second: _right,
          secondAlpha: 0,
        ),
      ],
      groupDescriptions: const {'grp_fg_disabled': '双手拍手'},
    ));

    expect(descriptions['grp_recipe_disabled'], contains('语义未标注'));
    expect(descriptions['grp_recipe_disabled'], isNot(contains('双手拍手')));
  });

  test(
    'semantic text after a multi-stage occupancy arrow remains searchable',
    () {
      final descriptions = motionRecipePromptDescriptions((
        recipes: [
          _recipe('grp_recipe_multistage', [
            [_body],
            [_left, _right],
          ]),
        ],
        groups: [
          _group(id: 'grp_eh_wait', first: _body),
          dualHand,
        ],
        groupDescriptions: const {'grp_eh_wait': '安静等待', 'grp_fg_dual': '双手拍手'},
      ));
      expect(
        descriptions['grp_recipe_multistage'],
        contains('occupancy=E → 双手拍手'),
      );
      expect(descriptions['grp_recipe_multistage'], isNot(contains('语义未标注')));

      final selected = selectMotionCandidates(
        {...descriptions, 'grp_recipe_decoy': '双手叉腰；occupancy=FG'},
        '拍手',
        limit: 1,
      );
      expect(selected.keys.single, 'grp_recipe_multistage');
    },
  );
}
