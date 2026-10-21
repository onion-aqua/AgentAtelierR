import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:ryza_chat_mvp/src/realtime_call/fish_call_tts.dart';

void main() {
  FishCallTtsStream request(FishCallTtsClient client, {Uri? endpoint}) =>
      client.synthesize(
        apiKey: 'test-secret-never-log',
        voiceId: 'test-voice',
        text: '[gasping]こんにちは。',
        model: 'drama-3',
        speed: .8,
        endpoint: endpoint,
      );

  test(
    'sends the documented REST model header and progressive PCM body',
    () async {
      final audio = StreamController<List<int>>();
      final seen = <Uint8List>[];
      final firstChunk = Completer<void>();
      final transport = _FakeClient((request) async {
        expect(request.url.toString(), 'https://api.fish.audio/v1/tts');
        expect(request.followRedirects, isFalse);
        expect(request.headers['model'], 'drama-3');
        expect(
          request.headers['Authorization'],
          'Bearer test-secret-never-log',
        );
        final body = jsonDecode((request as http.Request).body) as Map;
        expect(body['text'], 'こんにちは。');
        expect(body['reference_id'], 'test-voice');
        expect(body['format'], 'pcm');
        expect(body['sample_rate'], 24000);
        expect(body['latency'], 'low');
        expect(body.containsKey('streaming'), isFalse);
        expect((body['prosody'] as Map)['speed'], .8);
        return http.StreamedResponse(
          audio.stream,
          200,
          headers: {'content-type': 'application/octet-stream'},
        );
      });
      final stream = request(FishCallTtsClient(clientFactory: () => transport));
      final done = Completer<void>();
      stream.pcm.listen((chunk) {
        seen.add(chunk);
        if (!firstChunk.isCompleted) firstChunk.complete();
      }, onDone: done.complete);
      audio.add([1, 2, 3]);
      await firstChunk.future;
      // Delivery does not wait for the HTTP response to finish. A split sample
      // is carried to the next network chunk rather than losing a PCM byte.
      expect(seen.single, [1, 2]);
      expect(done.isCompleted, isFalse);
      audio.add([4, 5, 6]);
      await audio.close();
      await done.future;
      expect(seen.expand((x) => x).toList(), [1, 2, 3, 4, 5, 6]);
      expect(transport.sends, 1);
      expect(transport.closed, isTrue);
    },
  );

  test(
    'cancel aborts a request awaiting headers without retry or late audio',
    () async {
      final sent = Completer<void>();
      final transport = _FakeClient((request) async {
        sent.complete();
        await (request as http.Abortable).abortTrigger;
        throw http.RequestAbortedException(request.url);
      });
      final stream = request(FishCallTtsClient(clientFactory: () => transport));
      final output = stream.pcm.toList();
      await sent.future;
      await stream.cancel();
      expect(await output, isEmpty);
      expect(transport.sends, 1);
      expect(transport.closed, isTrue);
      expect(stream.generationSubmitted, isTrue);
    },
  );

  test('cancelling before listen never submits a billable request', () async {
    var factories = 0;
    final client = FishCallTtsClient(
      clientFactory: () {
        factories++;
        throw StateError('must not open transport');
      },
    );
    final stream = request(client);
    await stream.cancel();
    expect(await stream.pcm.toList(), isEmpty);
    expect(factories, 0);
    expect(stream.generationSubmitted, isFalse);
  });

  test(
    'cancel releases the audio subscription and drops queued chunks',
    () async {
      var subscriptionCancelled = false;
      final source = StreamController<List<int>>(
        onCancel: () => subscriptionCancelled = true,
      );
      final firstChunk = Completer<void>();
      final chunks = <Uint8List>[];
      final transport = _FakeClient(
        (_) async => http.StreamedResponse(source.stream, 200),
      );
      final stream = request(FishCallTtsClient(clientFactory: () => transport));
      final done = Completer<void>();
      stream.pcm.listen((bytes) {
        chunks.add(bytes);
        if (!firstChunk.isCompleted) firstChunk.complete();
      }, onDone: done.complete);
      source.add([1, 2]);
      await firstChunk.future;
      await stream.cancel();
      source.add([3, 4]);
      await done.future;
      await source.close();
      expect(subscriptionCancelled, isTrue);
      expect(chunks.expand((x) => x).toList(), [1, 2]);
      expect(transport.closed, isTrue);
      expect(transport.sends, 1);
    },
  );

  test('402 is sanitized and never retried or redirected', () async {
    final transport = _FakeClient(
      (_) async => http.StreamedResponse(
        Stream.value(utf8.encode('{"message":"test-secret-never-log"}')),
        402,
        headers: {'x-request-id': 'request-safe-123'},
      ),
    );
    final stream = request(FishCallTtsClient(clientFactory: () => transport));
    await expectLater(
      stream.pcm.toList(),
      throwsA(
        isA<FishCallTtsException>()
            .having((e) => e.statusCode, 'HTTP status', 402)
            .having((e) => e.requestId, 'request ID', 'request-safe-123')
            .having(
              (e) => e.toString(),
              'safe error',
              isNot(contains('test-secret-never-log')),
            ),
      ),
    );
    expect(transport.sends, 1);
    expect(transport.closed, isTrue);
  });

  test('redirect is refused before forwarding the credential', () async {
    final transport = _FakeClient((request) async {
      expect(request.followRedirects, isFalse);
      return http.StreamedResponse(
        const Stream.empty(),
        307,
        headers: {'location': 'https://untrusted.invalid/steal'},
      );
    });
    final stream = request(FishCallTtsClient(clientFactory: () => transport));
    await expectLater(
      stream.pcm.toList(),
      throwsA(
        isA<FishCallTtsException>().having(
          (e) => e.code,
          'code',
          'redirect_refused',
        ),
      ),
    );
    expect(transport.sends, 1);
  });

  test(
    'header timeout closes transport and marks unknown outcome once',
    () async {
      final transport = _FakeClient((request) async {
        await (request as http.Abortable).abortTrigger;
        throw http.RequestAbortedException(request.url);
      });
      final stream = request(
        FishCallTtsClient(
          clientFactory: () => transport,
          requestTimeout: const Duration(milliseconds: 10),
        ),
      );
      await expectLater(
        stream.pcm.toList(),
        throwsA(
          isA<FishCallTtsException>()
              .having((e) => e.code, 'code', 'timeout')
              .having((e) => e.outcomeUnknown, 'unknown outcome', isTrue),
        ),
      );
      expect(transport.sends, 1);
      expect(transport.closed, isTrue);
    },
  );

  test(
    'stalled audio timeout does not resubmit after partial playback',
    () async {
      final audio = StreamController<List<int>>();
      final transport = _FakeClient(
        (_) async => http.StreamedResponse(audio.stream, 200),
      );
      final stream = request(
        FishCallTtsClient(
          clientFactory: () => transport,
          chunkTimeout: const Duration(milliseconds: 10),
        ),
      );
      final result = stream.pcm.toList();
      audio.add([1, 2]);
      await expectLater(
        result,
        throwsA(
          isA<FishCallTtsException>().having((e) => e.code, 'code', 'timeout'),
        ),
      );
      await audio.close();
      expect(transport.sends, 1);
      expect(transport.closed, isTrue);
    },
  );

  test(
    'HTML, compressed, empty, odd and excessive audio are rejected',
    () async {
      for (final scenario in [
        ('text/html', <int>[1, 2], 'unexpected_audio_format'),
        ('audio/mpeg', <int>[1, 2], 'unexpected_audio_format'),
        ('audio/pcm', <int>[], 'truncated_audio'),
        ('audio/pcm', <int>[1], 'truncated_audio'),
        ('audio/pcm', List<int>.filled(50, 0), 'audio_limit'),
      ]) {
        final transport = _FakeClient(
          (_) async => http.StreamedResponse(
            Stream.value(scenario.$2),
            200,
            headers: {'content-type': scenario.$1},
          ),
        );
        final stream = request(
          FishCallTtsClient(
            clientFactory: () => transport,
            maximumAudioDuration: const Duration(milliseconds: 1),
          ),
        );
        await expectLater(
          stream.pcm.toList(),
          throwsA(
            isA<FishCallTtsException>().having(
              (e) => e.code,
              'code',
              scenario.$3,
            ),
          ),
        );
        expect(transport.sends, 1);
        expect(transport.closed, isTrue);
      }
    },
  );

  test('unsafe endpoint, empty speech and header injection never submit', () {
    var factories = 0;
    final client = FishCallTtsClient(
      clientFactory: () {
        factories++;
        throw StateError('must not open transport');
      },
    );
    for (final endpoint in [
      'http://api.fish.audio/v1/tts',
      'https://name:secret@api.fish.audio/v1/tts',
      'https://api.fish.audio/v1/tts?key=secret',
    ]) {
      expect(
        () => request(client, endpoint: Uri.parse(endpoint)),
        throwsA(isA<FishCallTtsException>()),
      );
    }
    for (final text in ['', '[gasping][sighing]', 'a' * 2001]) {
      expect(
        () => client.synthesize(
          apiKey: 'key',
          text: text,
          voiceId: 'voice',
          model: 'drama-3',
        ),
        throwsA(isA<FishCallTtsException>()),
      );
    }
    expect(
      () => client.synthesize(
        apiKey: 'key',
        text: 'Hello',
        voiceId: 'voice',
        model: 'drama-3\r\nInjected: yes',
      ),
      throwsA(isA<FishCallTtsException>()),
    );
    expect(factories, 0);
  });
}

class _FakeClient extends http.BaseClient {
  _FakeClient(this.onSend);
  final Future<http.StreamedResponse> Function(http.BaseRequest) onSend;
  var sends = 0;
  var closed = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    sends++;
    return onSend(request);
  }

  @override
  void close() => closed = true;
}
