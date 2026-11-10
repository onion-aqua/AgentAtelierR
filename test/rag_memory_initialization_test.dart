import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ryza_chat_mvp/src/rag_memory_embeddings.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const pathProvider = MethodChannel('plugins.flutter.io/path_provider');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() => messenger.setMockMethodCallHandler(pathProvider, null));

  test(
    'storage failure settles all initialization callers and allows retry',
    () async {
      final storageReady = Completer<void>();
      var requests = 0;
      messenger.setMockMethodCallHandler(pathProvider, (_) async {
        requests++;
        await storageReady.future;
        throw PlatformException(code: 'temporary_storage_failure');
      });
      final encoder = RagMemoryEmbeddings();
      addTearDown(encoder.dispose);
      final first = expectLater(
        encoder.initialize(),
        throwsA(isA<PlatformException>()),
      );
      final concurrent = expectLater(
        encoder.initialize(),
        throwsA(isA<PlatformException>()),
      );
      storageReady.complete();
      await Future.wait([first, concurrent])
          .timeout(const Duration(seconds: 2));
      expect(requests, 1);
      expect(encoder.available, isFalse);

      await expectLater(
        encoder.initialize().timeout(const Duration(seconds: 2)),
        throwsA(isA<PlatformException>()),
      );
      expect(requests, 2);
    },
  );

  test(
    'dispose releases concurrent callers before pending storage completes',
    () async {
      final directory = Completer<String>();
      messenger.setMockMethodCallHandler(pathProvider, (_) => directory.future);
      final encoder = RagMemoryEmbeddings();
      final first = expectLater(encoder.initialize(), throwsStateError);
      final concurrent = expectLater(encoder.initialize(), throwsStateError);
      await encoder.dispose();
      await concurrent.timeout(const Duration(seconds: 2));
      directory.complete('unused-after-dispose');
      await first.timeout(const Duration(seconds: 2));
      expect(encoder.available, isFalse);
      await expectLater(encoder.initialize(), throwsStateError);
    },
  );
}
