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
  test('retrieval ranks descriptions without executing user instructions', () {
    final result = selectMotionCandidates(
      {'grp_a': '挥手问候', 'grp_b': '抱臂思考', 'grp_c': '安静等待'},
      '她抱臂思考片刻',
      limit: 1,
    );
    expect(result.keys.single, 'grp_b');
  });
}
