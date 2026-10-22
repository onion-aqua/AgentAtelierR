import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:ryza_chat_mvp/src/speech_preparation.dart';
import 'package:ryza_chat_mvp/src/fish_mcp_protocol.dart';

Future<void> tick() => Future<void>.delayed(Duration.zero);

void main() {
  test(
    'consumer capacity limits buffered and pending clips together',
    () async {
      final started = <int>[];
      final queue = OrderedSpeechPreparation<int>(
        length: 6,
        prepare: (i) async {
          started.add(i);
          return i;
        },
        dispose: (_) {},
        isCurrent: () => true,
      );
      await queue.take(0, capacity: 3);
      await queue.take(1, capacity: 2);
      await queue.take(2, capacity: 1);
      expect(started, [0, 1, 2]);
      queue.close();
    },
  );

  test(
    'two invalid concurrent clips do not admit a speculative third',
    () async {
      final started = <int>[];
      final queue = OrderedSpeechPreparation<int>(
        length: 3,
        prepare: (i) async {
          started.add(i);
          throw const TtsAudioQualityException('audio_silent', 'silent');
        },
        dispose: (_) {},
        isCurrent: () => true,
      );
      queue.prefetch();
      await tick();
      expect((await queue.take(0)).error, isNotNull);
      queue.prefetch();
      expect((await queue.take(1)).error, isNotNull);
      queue.close();
      expect(started, [0, 1]);
    },
  );

  test(
    'two requests start concurrently but consumption stays ordered and bounded',
    () async {
      final jobs = List.generate(5, (_) => Completer<int>());
      final started = <int>[];
      final queue = OrderedSpeechPreparation<int>(
        length: 5,
        prepare: (i) {
          started.add(i);
          return jobs[i].future;
        },
        dispose: (_) {},
        isCurrent: () => true,
      );
      queue.prefetch();
      expect(started, [0, 1]);
      jobs[1].complete(1);
      await tick();
      queue.prefetch();
      expect(started, [0, 1]);
      var firstReturned = false;
      final first = queue.take(0).then((v) {
        firstReturned = true;
        return v.unwrap();
      });
      await tick();
      expect(firstReturned, isFalse);
      jobs[0].complete(0);
      expect(await first, 0);
      queue.prefetch();
      expect(started, [0, 1, 2]);
      expect((await queue.take(1)).unwrap(), 1);
      queue.close();
      jobs[2].complete(2);
      await tick();
      expect(started, [0, 1, 2]);
    },
  );

  test(
    'cancel disposes ready and late results exactly once without starting more',
    () async {
      final jobs = [Completer<int>(), Completer<int>()];
      final disposed = <int>[];
      final queue = OrderedSpeechPreparation<int>(
        length: 8,
        prepare: (i) => jobs[i].future,
        dispose: disposed.add,
        isCurrent: () => true,
      );
      queue.prefetch();
      jobs[1].complete(1);
      await tick();
      final taking = expectLater(queue.take(0), throwsStateError);
      queue.close();
      queue.close();
      jobs[0].complete(0);
      await taking;
      await tick();
      expect(disposed.toSet(), {0, 1});
      expect(disposed.length, 2);
    },
  );

  test(
    'outcome unknown stops admission immediately even when out of order',
    () async {
      final first = Completer<int>();
      final started = <int>[];
      final error = FishMcpException(
        stage: 'transport',
        code: 'timeout',
        message: 'unknown',
        outcomeUnknown: true,
        generationSubmitted: true,
      );
      final queue = OrderedSpeechPreparation<int>(
        length: 5,
        prepare: (i) {
          started.add(i);
          return i == 0 ? first.future : Future.error(error);
        },
        dispose: (_) {},
        isCurrent: () => true,
      );
      queue.prefetch();
      await tick();
      first.complete(0);
      expect((await queue.take(0)).unwrap(), 0);
      queue.prefetch();
      expect((await queue.take(1)).error, same(error));
      expect(started, [0, 1]);
      queue.close();
    },
  );

  test('local and rate limited providers use one slot without retry', () async {
    expect(SpeechConcurrencyPolicy.limit('local'), 1);
    expect(SpeechConcurrencyPolicy.limit('rate-test'), 2);
    SpeechConcurrencyPolicy.observe(
      'rate-test',
      FishMcpException(
        stage: 'transport',
        code: 'http_error',
        message: 'limited',
        status: 429,
      ),
    );
    expect(SpeechConcurrencyPolicy.limit('rate-test'), 1);
    final jobs = [Completer<int>(), Completer<int>()];
    final started = <int>[];
    final queue = OrderedSpeechPreparation<int>(
      length: 2,
      concurrency: 1,
      prepare: (i) {
        started.add(i);
        return jobs[i].future;
      },
      dispose: (_) {},
      isCurrent: () => true,
    );
    queue.prefetch();
    expect(started, [0]);
    jobs[0].complete(0);
    await queue.take(0);
    queue.prefetch();
    expect(started, [0, 1]);
    queue.close();
    jobs[1].complete(1);
    await tick();
  });
}
