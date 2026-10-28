import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:ryza_chat_mvp/src/app_controller.dart';
import 'package:ryza_chat_mvp/src/app_localization.dart';
import 'package:ryza_chat_mvp/src/realtime_call/call_reply.dart';
import 'package:ryza_chat_mvp/src/tts_text_normalizer.dart';

void main() {
  CallReplyRequest request({
    LlmProvider provider = LlmProvider.openAiCompatible,
  }) => CallReplyRequest(
    prompt: 'phone prompt',
    messages: const [ChatMessage(text: 'hello', isUser: true)],
    provider: provider,
    baseUrl: provider == LlmProvider.gemini
        ? 'https://generativelanguage.googleapis.com/v1beta'
        : 'https://example.test/v1',
    model: 'test-model',
    characterId: 'ryza',
    openAiSlot: 0,
  );

  test(
    'OpenAI call uses one non-redirecting POST and streams deltas',
    () async {
      final client = _FakeClient((sent) async {
        expect(sent.method, 'POST');
        expect(sent.url.toString(), 'https://example.test/v1/chat/completions');
        expect(sent.followRedirects, isFalse);
        final body = jsonDecode((sent as http.Request).body) as Map;
        expect(body['stream'], isTrue);
        expect((body['messages'] as List).first['role'], 'system');
        return http.StreamedResponse(
          Stream.value(
            utf8.encode(
              'data: {"choices":[{"delta":{"content":"こんにちは"}}]}\n\n'
              'data: {"choices":[{"delta":{"content":"。"}}]}\n\n'
              'data: [DONE]\n\n',
            ),
          ),
          200,
          headers: {'content-type': 'text/event-stream'},
        );
      });
      final backend = DirectCallReplyBackend(
        clientFactory: () => client,
        keyReader: (_, _) async => 'secret',
      );
      expect(await backend.reply(request()).join(), 'こんにちは。');
      expect(client.sends, 1);
      expect(client.closed, isTrue);
    },
  );

  test('retryable status is surfaced after exactly one POST', () async {
    final client = _FakeClient(
      (_) async => http.StreamedResponse(Stream.value([1, 2]), 503),
    );
    final backend = DirectCallReplyBackend(
      clientFactory: () => client,
      keyReader: (_, _) async => 'secret',
    );
    await expectLater(
      backend.reply(request()).toList(),
      throwsA(
        isA<Exception>().having(
          (error) => error.toString(),
          'message',
          contains('未自动重试'),
        ),
      ),
    );
    expect(client.sends, 1);
  });

  test('accepts an OpenAI compatible non-SSE JSON response', () async {
    final client = _FakeClient(
      (_) async => http.StreamedResponse(
        Stream.value(
          utf8.encode('{"choices":[{"message":{"content":"普通响应。"}}]}'),
        ),
        200,
        headers: {'content-type': 'application/json'},
      ),
    );
    final backend = DirectCallReplyBackend(
      clientFactory: () => client,
      keyReader: (_, _) async => 'secret',
    );
    expect(await backend.reply(request()).join(), '普通响应。');
    expect(client.sends, 1);
  });

  test('redirect is refused without forwarding a second request', () async {
    final client = _FakeClient((sent) async {
      expect(sent.followRedirects, isFalse);
      return http.StreamedResponse(
        const Stream.empty(),
        307,
        headers: {'location': 'https://untrusted.invalid/steal'},
      );
    });
    final backend = DirectCallReplyBackend(
      clientFactory: () => client,
      keyReader: (_, _) async => 'secret',
    );
    await expectLater(
      backend.reply(request()).toList(),
      throwsA(isA<Exception>()),
    );
    expect(client.sends, 1);
  });

  test('cancellation while loading key never opens a transport', () async {
    final key = Completer<String>();
    var factories = 0;
    final backend = DirectCallReplyBackend(
      clientFactory: () {
        factories++;
        throw StateError('must not send');
      },
      keyReader: (_, _) => key.future,
    );
    final subscription = backend.reply(request()).listen((_) {});
    await subscription.cancel();
    key.complete('secret');
    await Future<void>.delayed(Duration.zero);
    expect(factories, 0);
  });

  test('Gemini call uses native one-shot interactions schema', () async {
    final client = _FakeClient((sent) async {
      expect(
        sent.url.toString(),
        'https://generativelanguage.googleapis.com/v1beta/interactions',
      );
      expect(sent.headers['x-goog-api-key'], 'secret');
      expect(sent.headers.containsKey('Authorization'), isFalse);
      final body = jsonDecode((sent as http.Request).body) as Map;
      expect(body['system_instruction'], 'phone prompt');
      return http.StreamedResponse(
        Stream.value(
          utf8.encode(
            'data: {"event_type":"content.delta","delta":{"type":"text","text":"はい。"}}\n\n'
            'data: {"event_type":"interaction.completed","interaction":{"status":"completed"}}\n\n',
          ),
        ),
        200,
        headers: {'content-type': 'text/event-stream'},
      );
    });
    final backend = DirectCallReplyBackend(
      clientFactory: () => client,
      keyReader: (_, _) async => 'secret',
    );
    expect(
      await backend.reply(request(provider: LlmProvider.gemini)).join(),
      'はい。',
    );
    expect(client.sends, 1);
  });

  test('Gemini delta without interaction.completed is rejected', () async {
    final client = _FakeClient(
      (_) async => http.StreamedResponse(
        Stream.value(
          utf8.encode(
            'data: {"event_type":"content.delta","delta":{"type":"text","text":"partial"}}\n\n',
          ),
        ),
        200,
        headers: {'content-type': 'text/event-stream'},
      ),
    );
    final backend = DirectCallReplyBackend(
      clientFactory: () => client,
      keyReader: (_, _) async => 'secret',
    );
    await expectLater(
      backend.reply(request(provider: LlmProvider.gemini)).toList(),
      throwsA(
        isA<Exception>().having(
          (error) => error.toString(),
          'message',
          contains('提前结束'),
        ),
      ),
    );
    expect(client.sends, 1);
  });

  test(
    'CC translation sends only source text in one display-only request',
    () async {
      final client = _FakeClient((sent) async {
        final body = jsonDecode((sent as http.Request).body) as Map;
        final messages = body['messages'] as List;
        expect(messages, hasLength(2));
        expect(messages.first['content'], contains('通话字幕翻译器'));
        expect(messages.first['content'], isNot(contains('phone prompt')));
        expect(messages.last['content'], 'こんにちは。');
        return http.StreamedResponse(
          Stream.value(
            utf8.encode('{"choices":[{"message":{"content":"你好。"}}]}'),
          ),
          200,
          headers: {'content-type': 'application/json'},
        );
      });
      final backend = DirectCallReplyBackend(
        clientFactory: () => client,
        keyReader: (_, _) async => 'secret',
      );
      expect(
        await backend.translateCaption(
          request(),
          'こんにちは。',
          TranslationLanguage.chinese,
        ),
        '你好。',
      );
      expect(client.sends, 1);
      expect(client.closed, isTrue);
    },
  );

  group('CallStreamingSpeechBuffer', () {
    test(
      'ellipsis at hard boundary retains following quotation through TTS',
      () {
        final buffer = CallStreamingSpeechBuffer();
        final prefix = '${'あ' * 159}…';
        expect(buffer.add(prefix), isEmpty);
        expect(buffer.add('っ'), isEmpty);
        final parts = [...buffer.add('て言った。'), ...buffer.add('', flush: true)];
        final source = '$prefixって言った。';
        expect(parts.join(), source);
        expect(parts.map(normalizeFishAudioSynthesisText).join(), source);
      },
    );

    test(
      'long ellipsis retains a context mark without unbounded buffering',
      () {
        final buffer = CallStreamingSpeechBuffer();
        final prefix = '${'あ' * 159}${'…' * 30}';
        final parts = [...buffer.add(prefix)];
        expect(parts, isNotEmpty);
        expect(parts.every((part) => part.length <= 168), isTrue);
        expect(buffer.add('っ'), isEmpty);
        parts.addAll(buffer.add('て言った。'));
        parts.addAll(buffer.add('', flush: true));
        expect(parts.join(), '$prefixって言った。');
        expect(
          parts.map(normalizeFishAudioSynthesisText).join(),
          contains('って言った。'),
        );
      },
    );

    test(
      'hard cap does not discard tsu before a split quotation continues',
      () {
        final buffer = CallStreamingSpeechBuffer();
        final prefix = '${'あ' * 158}…';
        expect(buffer.add('$prefixっ'), isEmpty);
        expect(buffer.add('て'), ['$prefixって']);
        expect(buffer.add('言った。'), ['言った。']);
      },
    );

    test('filters split ellipsis breaths before captions and synthesis', () {
      final buffer = CallStreamingSpeechBuffer();
      expect(buffer.add('莱莎：あ…'), isEmpty);
      expect(buffer.add('…っ'), isEmpty);
      expect(buffer.add('、待って。'), ['あ……、待って。']);
      expect(buffer.add('……っ'), isEmpty);
      expect(buffer.add('て言ったよね。'), ['……って言ったよね。']);
      expect(buffer.add('…つ。'), ['…。']);
    });

    test('withholds split action tags before releasing dialogue', () {
      final buffer = CallStreamingSpeechBuffer();
      expect(buffer.add('[act'), isEmpty);
      expect(buffer.add('ion:wave]莱莎：你好'), isEmpty);
      expect(buffer.add('！'), ['你好！']);
    });

    test('drops narration, translation and private reasoning', () {
      final buffer = CallStreamingSpeechBuffer();
      expect(buffer.add('<think>不能朗读。'), isEmpty);
      expect(buffer.add('</think>旁白：房间很安静。'), isEmpty);
      expect(buffer.add('\n莱莎：听得见吗？'), ['听得见吗？']);
      expect(buffer.add('\n译文：Can you hear me?'), isEmpty);
    });

    test('drops unfinished markup at end of stream', () {
      final buffer = CallStreamingSpeechBuffer();
      expect(buffer.add('第一句。'), ['第一句。']);
      expect(buffer.add('[face:hap', flush: true), isEmpty);
    });

    test('allows a speaker prefix to resume after a hidden inline segment', () {
      final buffer = CallStreamingSpeechBuffer();
      expect(buffer.add('旁白：门开了。'), isEmpty);
      expect(buffer.add('莱莎：欢迎回来！'), ['欢迎回来！']);
    });
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
