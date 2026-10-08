import 'dart:io';

import 'package:flutter/services.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:ryza_chat_mvp/src/motion_recipe.dart';
import 'package:ryza_chat_mvp/src/motion_candidate_search.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('recipe catalogue is available outside encrypted skin bundle', () async {
    final loaded = MotionRecipe.parse(
      await rootBundle.loadString('assets/data/motion_recipes.json'),
    );
    expect(loaded.length, 132);
  });
  test(
    'generated extension catalogue is bundled and merges with built-ins',
    () async {
      final extension = MotionRecipe.parse(
        await rootBundle.loadString('assets/data/motion_recipes_extra.json'),
      );
      expect(extension.length, 38058);
      expect(extension.first.id, 'grp_recipe_145');
      expect(extension.last.id, 'grp_recipe_38202');
      expect(
        extension.map((recipe) => recipe.id).toSet().length,
        extension.length,
      );
      expect(
        extension.every(
          (recipe) =>
              {'universal', 'standing', 'seated'}.contains(recipe.category) &&
              recipe.skins.isNotEmpty &&
              recipe.stages.every(
                (stage) =>
                    stage.map((layer) => layer.track).toSet().length ==
                    stage.length,
              ),
        ),
        isTrue,
      );
      final builtIn = MotionRecipe.parse(
        File('assets/data/motion_recipes.json').readAsStringSync(),
      );
      final merged = MotionRecipe.merge([builtIn, extension]);
      expect(merged.length, 38190);
      expect(merged.map((recipe) => recipe.id).toSet().length, 38190);
    },
  );
  final recipes = MotionRecipe.parse(
    File('assets/data/motion_recipes.json').readAsStringSync(),
  );
  test(
    'all delivered recipes have isolated tracks and no facial overrides',
    () {
      expect(recipes.length, 132);
      expect(recipes.map((r) => r.id).toSet().length, 132);
      for (final recipe in recipes) {
        for (final stage in recipe.stages) {
          expect(stage.map((l) => l.track).toSet().length, stage.length);
          expect(stage.every((l) => l.name.startsWith('motion_')), isTrue);
          if (stage.any((l) => l.region == 'D')) expect(stage.length, 1);
          if (stage.any((l) => l.region == 'B')) {
            expect(
              stage.any((l) => l.region == 'F' || l.region == 'G'),
              isFalse,
            );
          }
        }
      }
    },
  );
  test('missing resources, wrong pose and cross-legged reject recipe', () {
    final recipe = recipes.first;
    final names = recipe.stages.expand((s) => s).map((l) => l.name).toSet();
    expect(recipe.available(names, recipe.base, 'sitting_normal'), isTrue);
    expect(recipe.available({}, recipe.base, 'sitting_normal'), isFalse);
    expect(recipe.available(names, 'other', 'sitting_normal'), isFalse);
    expect(recipe.available(names, recipe.base, 'sitting_agura'), isFalse);
  });
  test(
    'runtime availability rejects unsafe occupancy even when animations exist',
    () {
      final recipe = MotionRecipe.parse('''
      {"recipes":[{"id":"unsafe","name":"","description":"","base":"motion_A_001_idle","stages":[[
        {"name":"motion_add_B_001_active","region":"B","alpha":1,"speed":1},
        {"name":"motion_add_F_001_active","region":"F","alpha":1,"speed":1}
      ]]}]}
    ''').single;
      expect(
        recipe.available(
          {'motion_add_B_001_active', 'motion_add_F_001_active'},
          recipe.base,
          'sitting_normal',
        ),
        isFalse,
      );
    },
  );
  test(
    'optional planner metadata remains compatible with old recipe shape',
    () {
      final parsed = MotionRecipe.parse('''
      {"recipes":[{
        "id":"grp_extra",
        "name":"示例组合",
        "description":"用于规划器检索",
        "category":"explain",
        "posture":"seated",
        "tags":["解释", " 重点 ", 4, "解释"],
        "skins":["seated_01", "standing_99"],
        "skinOverrides":{"standing_99":{"stages":[]}, "ignored": 2},
        "base":"motion_A_001_idle",
        "stages":[[{"name":"motion_B_001_active","region":"B","alpha":1,"speed":1}]]
      }]}
    ''');
      expect(parsed.single.category, 'explain');
      expect(parsed.single.posture, 'seated');
      expect(parsed.single.tags, ['解释', '重点']);
      expect(parsed.single.skins, ['seated_01', 'standing_99']);
      expect(parsed.single.skinOverrides['standing_99'], isA<Map>());

      final oldShape = MotionRecipe.parse('''
      {"recipes":[{
        "id":"grp_old",
        "name":"旧格式",
        "description":"没有可选字段",
        "base":"motion_A_001_idle",
        "stages":[[{"name":"motion_B_001_active","region":"B","alpha":1,"speed":1}]]
      }]}
    ''').single;
      expect(oldShape.category, isEmpty);
      expect(oldShape.posture, isEmpty);
      expect(oldShape.tags, isEmpty);
      expect(oldShape.skins, isEmpty);
      expect(oldShape.skinOverrides, isEmpty);
    },
  );

  test('merge keeps built-in recipe when an extension repeats its id', () {
    final base = MotionRecipe.parse('''
      {"recipes":[{"id":"same","name":"内置","description":"","base":"motion_A_001_idle","stages":[[{"name":"motion_B_001_active","region":"B","alpha":1,"speed":1}]]}]}
    ''');
    final extension = MotionRecipe.parse('''
      {"recipes":[{"id":"same","name":"扩展","description":"","base":"motion_A_001_idle","stages":[[{"name":"motion_B_001_active","region":"B","alpha":1,"speed":1}]]},{"id":"new","name":"新增","description":"","base":"motion_A_001_idle","stages":[[{"name":"motion_B_001_active","region":"B","alpha":1,"speed":1}]]}]}
    ''');
    final merged = MotionRecipe.merge([base, extension]);
    expect(merged.map((recipe) => recipe.id), ['same', 'new']);
    expect(merged.first.name, '内置');
  });

  test(
    'posture and skin metadata narrow recipe availability when supplied',
    () {
      final recipe = MotionRecipe.parse('''
      {"recipes":[{
        "id":"scoped",
        "name":"限定",
        "description":"",
        "posture":"standing",
        "skins":["standing_99"],
        "base":"motion_A_001_idle",
        "stages":[[{"name":"motion_B_001_active","region":"B","alpha":1,"speed":1}]]
      }]}
    ''').single;
      final names = {'motion_B_001_active'};
      expect(
        recipe.available(
          names,
          recipe.base,
          'sitting_normal',
          appearanceId: 'standing_99',
          isStanding: true,
        ),
        isTrue,
      );
      expect(
        recipe.available(
          names,
          recipe.base,
          'sitting_normal',
          appearanceId: 'seated_01',
          isStanding: false,
        ),
        isFalse,
      );
    },
  );

  test('a seated outfit can reuse the seated recipe pool', () {
    final recipe = MotionRecipe.parse('''
    {"recipes":[{
      "id":"seated-scoped",
      "name":"坐姿限定",
      "description":"",
      "posture":"seated",
      "skins":["seated_01"],
      "base":"motion_A_001_idle",
      "stages":[[{"name":"motion_B_001_active","region":"B","alpha":1,"speed":1}]]
    }]}
    ''').single;
    expect(
      recipe.available(
        {'motion_B_001_active'},
        recipe.base,
        'sitting_normal',
        appearanceId: 'crf_skn_002_0006_01',
        baseAppearanceId: 'seated_01',
        appearanceAssetName: 'crf_skn_002_0006_01',
        isStanding: false,
      ),
      isTrue,
    );
  });

  test('retrieval ranks descriptions without executing user instructions', () {
    final result = selectMotionCandidates(
      {'grp_a': '挥手问候', 'grp_b': '抱臂思考', 'grp_c': '安静等待'},
      '她抱臂思考片刻',
      limit: 1,
    );
    expect(result.keys.single, 'grp_b');
  });
}
