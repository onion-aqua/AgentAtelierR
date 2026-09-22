/// Local text retrieval only ranks descriptions; it never executes a gesture.
Map<String, String> selectMotionCandidates(
  Map<String, String> catalogue,
  String query, {
  int limit = 16,
}) {
  Set<String> terms(String value) {
    final normalized = value.toLowerCase().replaceAll(
      RegExp(r'[^a-z0-9\u4e00-\u9fff\u3040-\u30ff]'),
      '',
    );
    return {
      for (var i = 0; i + 1 < normalized.length; i++)
        normalized.substring(i, i + 2),
    };
  }

  final queryTerms = terms(query);
  final scores = <String, int>{};
  for (final item in catalogue.entries) {
    scores[item.key] = terms(item.value).intersection(queryTerms).length;
  }
  final entries = catalogue.entries.toList()
    ..sort((a, b) {
      final score = scores[b.key]!.compareTo(scores[a.key]!);
      return score != 0 ? score : a.key.compareTo(b.key);
    });
  return Map.fromEntries(entries.take(limit));
}
