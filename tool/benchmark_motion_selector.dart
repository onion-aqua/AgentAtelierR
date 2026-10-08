import 'dart:convert';
import 'dart:io';

import 'package:ryza_chat_mvp/src/motion_candidate_search.dart';

// Desktop CPU benchmark, not an Android frame-time or LLM accuracy test.
Future<void> main() async {
  final catalogue = <String, String>{};
  for (final file in [
    'assets/data/motion_recipes.json',
    'assets/data/motion_recipes_extra.json',
  ]) {
    final document = jsonDecode(File(file).readAsStringSync()) as Map;
    for (final row in document['recipes'] as List) {
      catalogue[row['id'] as String] = '${row['name']}：${row['description']}';
    }
  }
  const query = '请挥手向我打招呼，轻轻晃脚，保持温柔的情绪。';
  final watch = Stopwatch()..start();
  await prepareMotionCandidateIndex(catalogue);
  final initial = selectMotionCandidates(catalogue, query);
  final coldMicros = watch.elapsedMicroseconds;
  watch.reset();
  for (var i = 0; i < 20; i++) {
    selectMotionCandidates(catalogue, query, recentKeys: initial.keys.take(4));
  }
  final warmMicros = watch.elapsedMicroseconds / 20;
  watch.reset();
  final expanded = selectMotionCandidates(catalogue, query, limit: 48);
  final expandedMicros = watch.elapsedMicroseconds;
  stdout.writeln(
    jsonEncode({
      'catalogue_count': catalogue.length,
      'cold_ms': coldMicros / 1000,
      'warm_average_ms': warmMicros / 1000,
      'expanded_ms': expandedMicros / 1000,
      'initial_count': initial.length,
      'expanded_count': expanded.length,
      'initial_json_characters': jsonEncode(initial).length,
      'expanded_json_characters': jsonEncode(expanded).length,
      'full_catalogue_json_characters': jsonEncode(catalogue).length,
    }),
  );
}
