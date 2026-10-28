import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:ryza_chat_mvp/src/rag_memory_retriever.dart';
import 'package:ryza_chat_mvp/src/rag_memory_runtime.dart';

const _blue = RagMemoryDocument(
  id: 'a',
  text: 'The old blue scarf was a birthday gift.',
);
const _red = RagMemoryDocument(
  id: 'b',
  text: 'A red crystal was discovered in the cave.',
);

void main() {
  test(
    'large archives retain query priority without cache thrashing',
    () async {
      var encoded = 0;
      final runtime = RagMemoryRuntime(
        embed: (texts) async {
          encoded += texts.length;
          return texts.map((_) => [1.0, 0.0]).toList();
        },
      );
      final documents = [
        const RagMemoryDocument(id: 'old', text: 'blue scarf birthday gift'),
        for (var i = 1; i <= 4097; i++)
          RagMemoryDocument(id: '$i', text: 'unrelated stone $i', sequence: i),
      ];
      Future<void> prepare() => runtime.prepare(
        query: 'blue scarf',
        documents: documents,
        isCurrent: () => true,
        timeout: const Duration(seconds: 30),
      );
      await prepare();
      expect(encoded, 4097); // Query plus a bounded 4096-source window.
      expect(
        runtime
            .retrieve(query: 'blue scarf', documents: documents)
            .first
            .document
            .id,
        'old',
      );
      await prepare();
      expect(encoded, 4097); // No repeated eviction/re-encoding of the archive.
      await runtime.dispose();
    },
  );

  test('unchanged documents and same query reuse cached vectors', () async {
    final batches = <List<String>>[];
    final runtime = RagMemoryRuntime(
      embed: (texts) async {
        batches.add(texts);
        return texts.map((_) => [1.0, 0.0]).toList();
      },
    );
    await runtime.prepare(
      query: 'blue scarf',
      documents: [_blue],
      isCurrent: () => true,
    );
    await runtime.prepare(
      query: 'blue scarf',
      documents: [_blue],
      isCurrent: () => true,
    );
    expect(batches, [
      ['blue scarf'],
      [_blue.text],
    ]);
    await runtime.prepare(
      query: 'red crystal',
      documents: [_blue, _red],
      isCurrent: () => true,
    );
    expect(batches.skip(2).toList(), [
      ['red crystal'],
      [_red.text],
    ]);
    expect(runtime.status, '本地语义与关键词混合检索');
    await runtime.dispose();
  });

  test(
    'timeout keeps lexical retrieval available and late vectors are reused',
    () async {
      final ready = Completer<List<List<double>>>();
      var first = true;
      final runtime = RagMemoryRuntime(
        embed: (texts) async {
          if (first) {
            first = false;
            return ready.future;
          }
          return texts.map((_) => [1.0, 0.0]).toList();
        },
      );
      await runtime.prepare(
        query: 'blue scarf',
        documents: [_blue],
        isCurrent: () => true,
        timeout: const Duration(milliseconds: 2),
      );
      expect(
        runtime
            .retrieve(query: 'blue scarf', documents: [_blue])
            .single
            .document
            .id,
        'a',
      );
      ready.complete([
        [1, 0],
      ]);
      await Future<void>.delayed(const Duration(milliseconds: 5));
      expect(runtime.status, '本地语义与关键词混合检索');
      await runtime.dispose();
    },
  );

  test(
    'invalidated same query schedules fresh work without old corpus evidence',
    () async {
      final ready = Completer<List<List<double>>>();
      var calls = 0;
      final runtime = RagMemoryRuntime(
        embed: (texts) async {
          calls++;
          if (calls == 1) return ready.future;
          return texts.map((_) => [1.0, 0.0]).toList();
        },
      );
      var oldCurrent = true;
      final old = runtime.prepare(
        query: 'blue scarf',
        documents: [_blue],
        isCurrent: () => oldCurrent,
      );
      await Future<void>.delayed(Duration.zero);
      oldCurrent = false;
      runtime.invalidate(clearVectors: true);
      final current = runtime.prepare(
        query: 'blue scarf',
        documents: [_red],
        isCurrent: () => true,
      );
      ready.complete([
        [1, 0],
      ]);
      await old;
      await current;
      expect(calls, 3);
      expect(
        runtime.retrieve(query: 'blue scarf', documents: []).isEmpty,
        isTrue,
      );
      await runtime.dispose();
    },
  );

  test(
    'encoder errors fall back to lexical instead of failing conversation',
    () async {
      final runtime = RagMemoryRuntime(
        embed: (_) async => throw StateError('unavailable'),
      );
      await runtime.prepare(
        query: 'blue scarf',
        documents: [_blue],
        isCurrent: () => true,
      );
      expect(runtime.status, contains('关键词回退'));
      expect(
        runtime
            .retrieve(query: 'blue scarf', documents: [_blue])
            .single
            .document
            .id,
        'a',
      );
      expect(
        runtime.retrieve(query: 'volcanic spaceship', documents: [_blue]),
        isEmpty,
      );
      await runtime.dispose();
    },
  );
}
