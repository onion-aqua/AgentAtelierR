import 'package:flutter_test/flutter_test.dart';
import 'package:ryza_chat_mvp/src/motion_candidate_search.dart';

void main() {
  test(
    'Japanese and English gestures retrieve Chinese catalogue semantics',
    () {
      const catalogue = {
        'grp_b_arms': '双手抱臂，安静思考',
        'grp_fg_clap': '双手拍手，庆祝成功',
        'grp_fg_wave': '挥手问候',
      };
      expect(
        selectMotionCandidates(catalogue, '腕を組んで考える', limit: 1).keys.single,
        'grp_b_arms',
      );
      expect(
        selectMotionCandidates(
          catalogue,
          'Please clap your hands',
          limit: 1,
        ).keys.single,
        'grp_fg_clap',
      );
      expect(
        selectMotionCandidates(catalogue, 'こんにちは、手を振って', limit: 1).keys.single,
        'grp_fg_wave',
      );
    },
  );
  test('selection stays within the requested context window', () {
    final catalogue = <String, String>{
      for (var i = 0; i < 1000; i++)
        'grp_fg_${i.toString().padLeft(4, '0')}': '自然等待动作$i',
    };

    final result = selectMotionCandidates(catalogue, '等待', limit: 16);

    expect(result, hasLength(16));
    expect(result.keys.toSet().length, result.length);
    // Re-running the same query must produce the same prompt window. This is
    // important because an unstable tie order makes the planner look random.
    expect(
      selectMotionCandidates(catalogue, '等待', limit: 16).keys,
      result.keys,
    );
  });

  test('a matching phrase outranks a single-character overlap', () {
    final result = selectMotionCandidates(
      const {
        'grp_fg_wave': '挥手问候，轻轻抬起右手',
        'grp_b_hand': '双手交叠，安静思考',
        'grp_c_wait': '坐姿等待，脚尖轻晃',
      },
      '她挥手向我问候',
      limit: 1,
    );

    expect(result.keys.single, 'grp_fg_wave');
  });

  test(
    'recently played groups are demoted while an equivalent fresh group wins',
    () {
      final result = selectMotionCandidates(
        const {'grp_fg_recent': '挥手问候', 'grp_b_fresh': '挥手问候'},
        '挥手问候',
        limit: 1,
        recentKeys: ['grp_fg_recent'],
      );

      expect(result.keys.single, 'grp_b_fresh');
    },
  );

  test('preferred groups break semantic ties deterministically', () {
    final result = selectMotionCandidates(
      const {'grp_fg_a': '自然等待', 'grp_fg_b': '自然等待'},
      '自然等待',
      limit: 1,
      preferredKeys: ['grp_fg_b'],
    );

    expect(result.keys.single, 'grp_fg_b');
  });

  test('generic matches retain a mix of occupancy buckets', () {
    final result = selectMotionCandidates(
      const {
        'grp_b_torso': '自然等待',
        'grp_c_legs': '自然等待',
        'grp_fg_hands': '自然等待',
        'grp_eh_sway': '自然等待',
      },
      '自然等待',
      limit: 4,
    );

    expect(result.keys.toSet(), {
      'grp_b_torso',
      'grp_c_legs',
      'grp_fg_hands',
      'grp_eh_sway',
    });
  });

  test('empty catalogue and non-positive limits are safe fallbacks', () {
    expect(selectMotionCandidates(const {}, '挥手'), isEmpty);
    expect(
      selectMotionCandidates(const {'grp_fg_wave': '挥手问候'}, '挥手', limit: 0),
      isEmpty,
    );
    expect(
      selectMotionCandidates(const {'grp_fg_wave': '挥手问候'}, '挥手', limit: -1),
      isEmpty,
    );
  });

  test(
    'no semantic hit still yields a bounded deterministic fallback window',
    () {
      const catalogue = {
        'grp_fg_b': '拍手',
        'grp_fg_a': '挥手',
        'grp_b_idle': '安静等待',
      };

      final result = selectMotionCandidates(catalogue, '完全没有对应动作', limit: 2);

      expect(result, hasLength(2));
      expect(result.keys, ['grp_b_idle', 'grp_fg_a']);
    },
  );
  test(
    'technical skin metadata does not outrank authored motion semantics',
    () {
      final result = selectMotionCandidates(
        const {'grp_fg_metadata': '安静等待；皮肤=挥手问候', 'grp_fg_wave': '挥手向你轻轻问候'},
        '挥手问候',
        limit: 1,
      );

      expect(result.keys.single, 'grp_fg_wave');
    },
  );

  test(
    'recipe diversity uses occupancy tracks rather than one recipe bucket',
    () {
      final result = selectMotionCandidates(
        const {
          'grp_recipe_a0': '自然等待；track=F',
          'grp_recipe_a1': '自然等待；track=F',
          'grp_recipe_a2': '自然等待；track=F',
          'grp_recipe_a3': '自然等待；track=F',
          'grp_recipe_b': '自然等待；track=C',
        },
        '自然等待',
        limit: 2,
      );

      expect(result.keys, ['grp_recipe_a0', 'grp_recipe_b']);
    },
  );
}
