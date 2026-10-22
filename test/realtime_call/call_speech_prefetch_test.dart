import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ryza_chat_mvp/src/realtime_call/call_speech_prefetch.dart';

Future<void> tick() => Future<void>.delayed(Duration.zero);

void main() {
  test(
    'unplayed prefetch error stops new admission and is observed immediately',
    () async {
      final errors = <Object>[];
      final started = <int>[];
      final failure = StateError('generation outcome unknown');
      final queue = CallSpeechPrefetch(
        isCurrent: () => true,
        onError: errors.add,
      );
      final items = List.generate(
        3,
        (i) => queue.add(() {
          started.add(i);
          return CallSpeech(
            i == 1 ? Stream.error(failure) : Stream.value(Uint8List(4)),
            () async {},
          );
        }),
      );
      await tick();
      expect(errors, [failure]);
      expect(await items[2].ready.future, isNull);
      await queue.cancel();
      expect(started, [0, 1]);
    },
  );

  test(
    'prefetch preserves first-chunk streaming and pauses later PCM',
    () async {
      final input = StreamController<Uint8List>();
      final queue = CallSpeechPrefetch(
        isCurrent: () => true,
        onError: (e) => fail('$e'),
      );
      final item = queue.add(() => CallSpeech(input.stream, () async {}));
      final speech = (await item.ready.future)!;
      final iterator = StreamIterator(speech.pcm);
      final first = iterator.moveNext();
      input.add(Uint8List.fromList([1]));
      expect(
        await first,
        isTrue,
      ); // Source is still open: do not buffer whole sentence.
      expect(iterator.current, [1]);
      input.add(Uint8List.fromList([2]));
      await tick();
      expect(input.isPaused, isTrue);
      expect(await iterator.moveNext(), isTrue);
      expect(iterator.current, [2]);
      await iterator.cancel();
      await queue.cancel();
      await input.close();
    },
  );

  test(
    'starts two streams, plays in order, admits third only after drain',
    () async {
      final started = <int>[];
      final cancelled = <int>[];
      final queue = CallSpeechPrefetch(
        isCurrent: () => true,
        onError: (e) => fail('$e'),
      );
      final items = List.generate(
        4,
        (i) => queue.add(() {
          started.add(i);
          return CallSpeech(Stream.value(Uint8List.fromList([i])), () async {
            cancelled.add(i);
          });
        }),
      );
      await tick();
      expect(started, [0, 1]);
      final played = <int>[];
      for (final item in items) {
        final speech = (await item.ready.future)!;
        await for (final bytes in speech.pcm) {
          played.add(bytes.single);
        }
        await queue.release(item);
      }
      await queue.cancel();
      expect(played, [0, 1, 2, 3]);
      expect(cancelled.toSet(), {0, 1, 2, 3});
      expect(cancelled.length, 4);
    },
  );

  test(
    'cancel clears unconsumed prefetched streams and queued sentences',
    () async {
      final started = <int>[];
      final cancelled = <int>[];
      final queue = CallSpeechPrefetch(
        isCurrent: () => true,
        onError: (e) => fail('$e'),
      );
      final items = List.generate(
        4,
        (i) => queue.add(() {
          started.add(i);
          return CallSpeech(Stream.value(Uint8List.fromList([i])), () async {
            cancelled.add(i);
          });
        }),
      );
      await tick();
      await queue.cancel();
      expect(started, [0, 1]);
      expect(cancelled, [0, 1]);
      expect(await items[2].ready.future, isNull);
      expect(await items[3].ready.future, isNull);
    },
  );
}
