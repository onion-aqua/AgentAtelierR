import 'dart:math' as math;

/// One complete piece of evidence. Ownership/visibility must be filtered by the
/// caller before retrieval; the index is never an authority for game state.
class RagMemoryDocument {
  const RagMemoryDocument({
    required this.id,
    required this.text,
    this.sequence = 0,
    this.source = 'archive',
    this.status = 'active',
    this.metadata = const {},
  });

  final String id;
  final String text;
  final int sequence;
  final String source;
  final String status;
  final Map<String, Object?> metadata;
}

class RagMemoryHit {
  const RagMemoryHit({required this.document, required this.score});

  final RagMemoryDocument document;
  final double score;
}

/// BM25 plus cosine similarity from a genuine, separately managed sentence
/// encoder. With no encoder the same API degrades to lexical retrieval only.
/// Unrelated high-importance entries cannot qualify solely from their metadata.
class RagMemoryRetriever {
  RagMemoryRetriever._();

  // Calibrated against the bundled DistilUSE question -> memory evaluation.
  // This is an evidence-candidate threshold, never proof that a recalled
  // passage answers every detail in the question. The generator must still
  // identify missing attributes and defer to authoritative current state.
  static const semanticThreshold = .35;

  static final _latin = RegExp(r'[a-z0-9]+(?:[_-][a-z0-9]+)*');
  static final _eastAsian = RegExp(
    r'[\u3040-\u30ff\u3400-\u9fff\uf900-\ufaff\uff66-\uff9f]+',
  );
  static final _spacesAndPunctuation = RegExp(r'[\s\p{P}\p{S}]', unicode: true);
  static const _latinStop = {
    'a',
    'an',
    'and',
    'are',
    'as',
    'at',
    'be',
    'been',
    'but',
    'by',
    'can',
    'could',
    'did',
    'do',
    'does',
    'for',
    'from',
    'had',
    'has',
    'have',
    'how',
    'i',
    'if',
    'in',
    'is',
    'it',
    'its',
    'me',
    'my',
    'of',
    'on',
    'or',
    'our',
    'please',
    'said',
    'say',
    'she',
    'so',
    'some',
    'that',
    'the',
    'their',
    'them',
    'then',
    'there',
    'these',
    'they',
    'this',
    'to',
    'us',
    'was',
    'we',
    'were',
    'what',
    'when',
    'where',
    'which',
    'who',
    'will',
    'with',
    'would',
    'you',
    'your',
    'remember',
    'recall',
    'before',
    'previous',
    'last',
  };
  static const _cjkStop = {
    '我们',
    '你们',
    '他们',
    '她们',
    '自己',
    '这个',
    '那个',
    '这些',
    '那些',
    '什么',
    '怎么',
    '如何',
    '之前',
    '以前',
    '上次',
    '当时',
    '刚才',
    '现在',
    '今天',
    '昨天',
    '明天',
    '已经',
    '还是',
    '是不是',
    '是否',
    '可以',
    '能不能',
    '记得',
    '记忆',
    '回忆',
    '一下',
    '一起',
    '之后',
    '然后',
    '因为',
    '所以',
    '关于',
    '那个时候',
    '说过',
    '告诉',
    '没有',
    '时候',
    '事情',
    '知道',
    'です',
    'ます',
    'した',
    'して',
    'いる',
    'ある',
    'だった',
    'でした',
    'する',
    'したの',
    'って',
    'こと',
    'もの',
    'あの',
    'その',
    'この',
    '何を',
    '覚えて',
    '覚えてる',
    '覚えている',
    '前に',
    '私たち',
    'いつ',
    'どう',
    'どこ',
    'かしら',
    'でしょう',
  };

  static List<RagMemoryHit> retrieve({
    required String query,
    required List<RagMemoryDocument> documents,
    Map<String, List<double>> embeddings = const {},
    List<double>? queryEmbedding,
    int limit = 6,
    int maxChars = 2400,
  }) {
    if (query.trim().isEmpty ||
        documents.isEmpty ||
        limit <= 0 ||
        maxChars <= 0) {
      return const [];
    }
    final queryTerms = _terms(query);
    final queryVector = _normalVector(queryEmbedding);
    if (queryTerms.isEmpty && queryVector == null) return const [];
    final valid = documents
        .where(
          (d) =>
              d.id.isNotEmpty &&
              d.text.trim().isNotEmpty &&
              !const {'deleted', 'withdrawn', 'invalid'}.contains(d.status),
        )
        .toList(growable: false);
    if (valid.isEmpty) return const [];

    final indexed = <_IndexedDocument>[];
    final frequencies = <String, int>{};
    var totalLength = 0;
    for (final doc in valid) {
      final keywords = doc.metadata['keywords'];
      final source = keywords is Iterable
          ? '${doc.text} ${keywords.whereType<String>().join(' ')}'
          : keywords is String
          ? '${doc.text} $keywords'
          : doc.text;
      final terms = _terms(source);
      final length = terms.values.fold<int>(0, (a, b) => a + b);
      totalLength += length;
      for (final term in terms.keys) {
        frequencies[term] = (frequencies[term] ?? 0) + 1;
      }
      indexed.add(_IndexedDocument(doc, terms, length));
    }
    final average = math.max(1.0, totalLength / indexed.length);
    final scored = <RagMemoryHit>[];
    for (final item in indexed) {
      var bm25 = 0.0;
      var sharedTerms = 0;
      for (final term in queryTerms.keys) {
        final tf = item.terms[term] ?? 0;
        if (tf == 0) continue;
        sharedTerms++;
        final df = frequencies[term]!;
        final idf = math.log(1 + (indexed.length - df + .5) / (df + .5));
        bm25 +=
            idf * tf * 2.2 / (tf + 1.2 * (.25 + .75 * item.length / average));
      }
      final dense = _cosine(queryVector, embeddings[item.document.id]);
      // No padding with important or recent but unrelated events. This is
      // especially important for sensitive memories and old relationship states.
      final lexicalMatch = sharedTerms > 0 && bm25 >= .18;
      final semanticMatch = dense != null && dense >= semanticThreshold;
      if (!lexicalMatch && !semanticMatch) continue;

      final lexical = bm25 / (bm25 + 2.5);
      final semantic = dense == null
          ? 0.0
          : ((dense - .1) / .9).clamp(0.0, 1.0);
      var score = .58 * lexical + .42 * semantic;
      if (dense == null) score = lexical;
      final exactIdentifier = queryTerms.keys.any(
        (term) =>
            RegExp(r'[0-9]').hasMatch(term) && item.terms.containsKey(term),
      );
      if (exactIdentifier) score += .08;
      final importance = item.document.metadata['importance'];
      if (importance is num && importance.isFinite) {
        score += .02 * (importance.toDouble().clamp(1, 5) - 1) / 4;
      }
      if (item.document.status == 'superseded') score *= .94;
      scored.add(RagMemoryHit(document: item.document, score: score));
    }
    scored.sort((a, b) {
      final score = b.score.compareTo(a.score);
      if (score != 0) return score;
      final sequence = b.document.sequence.compareTo(a.document.sequence);
      return sequence != 0 ? sequence : a.document.id.compareTo(b.document.id);
    });

    final selected = <RagMemoryHit>[];
    final texts = <String>[];
    final ids = <String>{};
    var remaining = maxChars;
    for (final hit in scored) {
      if (selected.length >= limit) break;
      if (ids.contains(hit.document.id)) continue;
      final cost = hit.document.text.runes.length;
      if (cost > remaining) continue;
      final comparable = hit.document.text.toLowerCase().replaceAll(
        _spacesAndPunctuation,
        '',
      );
      if (texts.any(
        (text) =>
            text == comparable ||
            text.length >= 32 &&
                comparable.length >= 32 &&
                (text.contains(comparable) || comparable.contains(text)),
      )) {
        continue;
      }
      remaining -= cost;
      selected.add(hit);
      ids.add(hit.document.id);
      texts.add(comparable);
    }
    return selected;
  }

  static Map<String, int> _terms(String input) {
    final terms = <String, int>{};
    final lower = input.toLowerCase();
    void add(String term) {
      if (_latinStop.contains(term) || _cjkStop.contains(term)) return;
      terms[term] = (terms[term] ?? 0) + 1;
    }

    for (final match in _latin.allMatches(lower)) {
      final token = match.group(0)!;
      add(token);
      // A small morphology fallback helps lexical retrieval without claiming to
      // replace multilingual sentence embeddings or applying it to identifiers.
      if (RegExp(r'^[a-z]{5,}$').hasMatch(token)) {
        if (token.endsWith('s') && !token.endsWith('ss')) {
          add(token.substring(0, token.length - 1));
        } else if (token.endsWith('ing') && token.length > 6) {
          add(token.substring(0, token.length - 3));
        }
      }
    }
    for (final match in _eastAsian.allMatches(lower)) {
      final runes = match.group(0)!.runes.toList(growable: false);
      if (runes.length == 1) add(String.fromCharCodes(runes));
      for (var start = 0; start < runes.length; start++) {
        for (
          var width = 2;
          width <= 3 && start + width <= runes.length;
          width++
        ) {
          add(String.fromCharCodes(runes.sublist(start, start + width)));
        }
      }
    }
    return terms;
  }

  static List<double>? _normalVector(List<double>? vector) {
    if (vector == null || vector.isEmpty || vector.any((v) => !v.isFinite)) {
      return null;
    }
    var squared = 0.0;
    for (final value in vector) {
      squared += value * value;
    }
    if (!squared.isFinite || squared <= 1e-20) return null;
    final length = math.sqrt(squared);
    return vector.map((v) => v / length).toList(growable: false);
  }

  static double? _cosine(List<double>? normalizedQuery, List<double>? vector) {
    if (normalizedQuery == null ||
        vector == null ||
        normalizedQuery.length != vector.length) {
      return null;
    }
    final normalized = _normalVector(vector);
    if (normalized == null) return null;
    var result = 0.0;
    for (var i = 0; i < normalized.length; i++) {
      result += normalizedQuery[i] * normalized[i];
    }
    return result.clamp(-1.0, 1.0);
  }
}

class _IndexedDocument {
  const _IndexedDocument(this.document, this.terms, this.length);
  final RagMemoryDocument document;
  final Map<String, int> terms;
  final int length;
}
