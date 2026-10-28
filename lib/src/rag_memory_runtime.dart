import 'dart:async';

import 'rag_memory_embeddings.dart';
import 'rag_memory_retriever.dart';

typedef RagEmbeddingFunction = Future<List<List<double>>> Function(
  List<String>,
);

/// Rebuildable vector cache. The caller supplies only its current save's sources.
class RagMemoryRuntime {
  RagMemoryRuntime({RagEmbeddingFunction? embed}) : _injectedEmbed = embed;

  final RagEmbeddingFunction? _injectedEmbed;
  RagMemoryEmbeddings? _model;
  final _vectors = <String, ({String text, List<double> vector})>{};
  Future<void> _tail = Future.value();
  int _generation = 0;
  bool _disposed = false;
  String _status = '尚未检索';
  String get status => _status;

  Future<List<List<double>>> _embed(List<String> text) =>
      _injectedEmbed?.call(text) ??
      (_model ??= RagMemoryEmbeddings()).embed(text);

  Map<String, List<double>> _documentVectors(
    List<RagMemoryDocument> documents,
  ) => {
    for (final document in documents)
      if (_vectors[document.id] case final cached?
          when cached.text == document.text)
        document.id: cached.vector,
  };

  void invalidate({bool clearVectors = false}) {
    _generation++;
    _pending = null;
    _pendingQuery = null;
    _query = '';
    _queryVector = null;
    if (clearVectors) _vectors.clear();
    _status = '尚未检索';
  }

  String _query = '';
  List<double>? _queryVector;
  Future<void>? _pending;
  String? _pendingQuery;

  Future<void> prepare({
    required String query,
    required List<RagMemoryDocument> documents,
    required bool Function() isCurrent,
    Duration timeout = const Duration(seconds: 3),
  }) async {
    if (_disposed || query.trim().isEmpty || documents.isEmpty) return;
    final generation = _generation;
    final pendingKey =
        '$query\u0000${documents.map((document) => '${document.id}:${document.text}').join('\u0000')}';
    if (_pendingQuery == pendingKey && _pending != null) {
      await _pending!.timeout(timeout, onTimeout: () {});
      return;
    }
    _status = '正在准备本地语义索引';
    // Serialize inference work. Timeout limits the request latency without
    // discarding completed, still-current incremental vector work.
    final future = _tail.then((_) async {
      if (_disposed || generation != _generation || !isCurrent()) return;
      try {
        if (_query != query || _queryVector == null) {
          final queryVectors = await _embed([query]);
          if (_disposed || generation != _generation || !isCurrent()) return;
          if (queryVectors.length != 1) {
            throw StateError('Invalid embedding batch');
          }
          _query = query;
          _queryVector = queryVectors.single;
        }
        // Bound native work as well as retained vectors. Indexing an unlimited
        // archive into a FIFO cache would evict this query's best sources and
        // recompute the same discarded history on every request. All original
        // sources remain available to lexical retrieval outside this window.
        final prioritized = documents.toList();
        final preferred = RagMemoryRetriever.retrieve(
          query: query,
          documents: documents,
          limit: 16,
          maxChars: 16000,
        ).map((hit) => hit.document.id).toSet();
        prioritized.sort((a, b) {
          final priority =
              (preferred.contains(b.id) ? 1 : 0) -
              (preferred.contains(a.id) ? 1 : 0);
          return priority != 0 ? priority : b.sequence.compareTo(a.sequence);
        });
        final indexed = prioritized.take(4096).toList();
        final retained = indexed.map((document) => document.id).toSet();
        _vectors.removeWhere((id, _) => !retained.contains(id));
        final missing = indexed
            .where((document) => _vectors[document.id]?.text != document.text)
            .toList();
        for (var offset = 0; offset < missing.length; offset += 8) {
          if (_disposed || generation != _generation || !isCurrent()) return;
          final batch = missing.skip(offset).take(8).toList();
          final vectors = await _embed(
            batch.map((document) => document.text).toList(),
          );
          if (_disposed || generation != _generation || !isCurrent()) return;
          if (vectors.length != batch.length) {
            throw StateError('Invalid embedding batch');
          }
          for (var index = 0; index < batch.length; index++) {
            final document = batch[index];
            _vectors.remove(document.id);
            _vectors[document.id] = (
              text: document.text,
              vector: vectors[index],
            );
          }
          // A first version uses bounded linear cosine search rather than a
          // database which could outlive a withdrawn or changed save.
          while (_vectors.length > 4096) {
            _vectors.remove(_vectors.keys.first);
          }
          await Future<void>.delayed(Duration.zero);
        }
        _status = '本地语义与关键词混合检索';
      } on Object {
        if (!_disposed && generation == _generation && isCurrent()) {
          _status = '关键词回退（本地语义暂不可用）';
        }
      }
    });
    _tail = future;
    _pending = future;
    _pendingQuery = pendingKey;
    await future.timeout(timeout, onTimeout: () {});
    future.whenComplete(() {
      if (identical(_pending, future)) {
        _pending = null;
        _pendingQuery = null;
      }
    });
  }

  List<RagMemoryHit> retrieve({
    required String query,
    required List<RagMemoryDocument> documents,
    int limit = 6,
    int maxChars = 2400,
  }) => RagMemoryRetriever.retrieve(
    query: query,
    documents: documents,
    embeddings: _documentVectors(documents),
    queryEmbedding: query == _query ? _queryVector : null,
    limit: limit,
    maxChars: maxChars,
  );

  Future<void> dispose() async {
    _disposed = true;
    invalidate(clearVectors: true);
    await _model?.dispose();
  }
}
