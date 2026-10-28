import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:onnxruntime/onnxruntime.dart';
import 'package:ryza_chat_mvp/src/rag_memory_embeddings.dart';

void main() {
  test(
    'real native ONNX pipeline returns multilingual unit sentence vectors',
    () {
      OrtEnv.instance.init(logId: 'AARMemoryNativeTest');
      final options = OrtSessionOptions()
        ..setIntraOpNumThreads(2)
        ..setInterOpNumThreads(1);
      final session = OrtSession.fromBuffer(
        File('assets/models/memory_rag/model.onnx').readAsBytesSync(),
        options,
      );
      final tokenizer = RagWordPieceTokenizer(
        File('assets/models/memory_rag/vocab.txt').readAsStringSync(),
      );
      const texts = [
        '我们约好明天一起去森林采集材料。',
        '明日は一緒に森へ素材を探しに行こうと約束しました。',
        'We promised to gather materials in the forest tomorrow.',
        '今天的天空很蓝。',
      ];
      final length = texts
          .map((text) => tokenizer.encode(text).ids.length)
          .reduce(math.max);
      final rows = texts
          .map((text) => tokenizer.encode(text, padTo: length))
          .toList();
      final inputs = {
        'input_ids': OrtValueTensor.createTensorWithDataList(
          Int64List.fromList(rows.expand((row) => row.ids).toList()),
          [rows.length, length],
        ),
        'attention_mask': OrtValueTensor.createTensorWithDataList(
          Int64List.fromList(rows.expand((row) => row.mask).toList()),
          [rows.length, length],
        ),
      };
      final run = OrtRunOptions();
      List<OrtValue?>? output;
      try {
        output = session.run(run, inputs);
        final vectors = (output.single!.value as List)
            .map((row) => (row as List).cast<double>())
            .toList();
        expect(vectors.length, texts.length);
        for (final vector in vectors) {
          expect(vector.length, 512);
          final norm = math.sqrt(
            vector.fold<double>(0, (sum, value) => sum + value * value),
          );
          expect(norm, closeTo(1, 1e-5));
        }
        double cosine(int left, int right) => List.generate(
          512,
          (index) => vectors[left][index] * vectors[right][index],
        ).fold<double>(0, (sum, value) => sum + value);
        expect(cosine(0, 1), greaterThan(.80));
        expect(cosine(0, 2), greaterThan(.85));
        expect(cosine(0, 3), lessThan(.30));
      } finally {
        for (final value in output ?? const <OrtValue?>[]) {
          value?.release();
        }
        for (final value in inputs.values) {
          value.release();
        }
        run.release();
        session.release();
        options.release();
      }
    },
    skip: Platform.environment['AAR_RAG_NATIVE'] != '1',
  );
}
