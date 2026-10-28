import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ryza_chat_mvp/src/rag_memory_embeddings.dart';

void main() {
  test(
    'cased WordPiece matches the real Hugging Face tokenizer across scripts',
    () {
      final file = File('assets/models/memory_rag/vocab.txt');
      final tokenizer = RagWordPieceTokenizer(file.readAsStringSync());
      final references = jsonDecode(
        File('test/fixtures/rag_wordpiece_reference.json').readAsStringSync(),
      ) as List;
      for (final row in references.cast<Map>()) {
        expect(
          tokenizer.encode(row['text'] as String).ids,
          row['ids'],
          reason: row['text'] as String,
        );
      }
    },
    skip: !File('assets/models/memory_rag/vocab.txt').existsSync(),
  );

  test(
    'WordPiece special tokens, padding and right truncation stay aligned',
    () {
      final tokenizer = RagWordPieceTokenizer(
        '[PAD]\n[UNK]\n[CLS]\n[SEP]\nHello\nworld\n##wide\n!\n',
      );
      final encoded = tokenizer.encode(
        'Hello worldwide!',
        maxTokens: 8,
        padTo: 8,
      );
      expect(encoded.ids, [2, 4, 5, 6, 7, 3, 0, 0]);
      expect(encoded.mask, [1, 1, 1, 1, 1, 1, 0, 0]);
      final shortened = tokenizer.encode('Hello worldwide!', maxTokens: 4);
      expect(shortened.ids, [2, 4, 5, 3]);
      expect(shortened.mask, [1, 1, 1, 1]);
      expect(tokenizer.encode('hello').ids, [2, 1, 3]);
      expect(() => tokenizer.encode('text', maxTokens: 1), throwsArgumentError);
    },
  );

  test(
    'Chinese basic tokenization avoids replacing entire sentences by UNK',
    () {
      final tokenizer = RagWordPieceTokenizer(
        '[PAD]\n[UNK]\n[CLS]\n[SEP]\n我\n爱\n茶\n。\n',
      );
      expect(tokenizer.encode('我爱茶。').ids, [2, 4, 5, 6, 7, 3]);
      expect(tokenizer.encode('我\u0000爱\t茶。').ids, [2, 4, 5, 6, 7, 3]);
    },
  );

  test(
    'injected backend normalizes finite vectors and validates shape',
    () async {
      final encoder = RagMemoryEmbeddings(
        backend: (texts) async => [
          for (final _ in texts) [3.0, 4.0, ...List.filled(510, 0.0)],
        ],
      );
      expect(encoder.available, isTrue);
      final batch = await encoder.embed(['a', 'b']);
      expect(batch.length, 2);
      expect(batch.first.length, 512);
      expect(batch.first[0], closeTo(.6, 1e-12));
      expect(batch.first[1], closeTo(.8, 1e-12));
      await encoder.dispose();
      expect(encoder.available, isFalse);
      await expectLater(encoder.embed(['a']), throwsStateError);
    },
  );

  test(
    'wrong dimension, empty vector, NaN and wrong batch are rejected',
    () async {
      for (final vectors in <List<List<double>>>[
        [
          [1],
        ],
        [List.filled(512, 0)],
        [
          [double.nan, ...List.filled(511, 0)],
        ],
        [],
      ]) {
        final encoder = RagMemoryEmbeddings(backend: (_) async => vectors);
        await expectLater(encoder.embed(['one']), throwsFormatException);
        await encoder.dispose();
      }
    },
  );

  test(
    'huge text or huge inference batch is rejected before any backend work',
    () async {
      var calls = 0;
      final encoder = RagMemoryEmbeddings(
        backend: (_) async {
          calls++;
          return [];
        },
      );
      expect(await encoder.embed([]), isEmpty);
      await expectLater(
        encoder.embed(List.filled(65, 'short')),
        throwsArgumentError,
      );
      await expectLater(encoder.embed(['x' * 4097]), throwsArgumentError);
      expect(calls, 0);
      await encoder.dispose();
    },
  );
}
