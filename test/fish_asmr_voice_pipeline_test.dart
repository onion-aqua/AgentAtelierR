import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ryza_chat_mvp/src/ai_services.dart';
import 'package:ryza_chat_mvp/src/app_controller.dart';
import 'package:ryza_chat_mvp/src/chat_segments.dart';
import 'package:ryza_chat_mvp/src/tts_text_normalizer.dart';

// Container identification is sufficient here: no decoder, TTS service,
// browser or device is used. Assertions inspect the actual outgoing JSON.
const _mp3 = <int>[0x49, 0x44, 0x33, 4, 0, 0, 0, 0, 0, 0];
const _voice = '1380fd182e0f44639df49e1ae8feeed8';
const _s2AsmrVoice = 'c5de0b3f9ac54e08b21fb63120e4ebdb';
const _s2WhisperCue =
    '[whispering intimately into the microphone, hushed and clearly articulated throughout]';

String _prepare(
  String text, {
  required bool asmr,
  TtsCueDensity density = TtsCueDensity.normal,
}) => normalizeFishAudioSynthesisText(
  applyFishEmotionIntensityPerSentence(
    text,
    TtsEmotionIntensity.off,
    density: density,
    asmr: asmr,
  ),
  asmr: asmr,
);

String _words(String text) => text
    .replaceAll(RegExp(r'\[[^\[\]\r\n]+\]'), '')
    .replaceAll(RegExp(r'\s+'), '');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('REST ASMR with emotion off keeps a single whole-script whisper across long sentences', () async {
    const original =
        '今日はここでゆっくり休もう。窓の外には静かな夜が広がっているよ。'
        '明日もまた会えるから、今は何も急がなくて大丈夫。'
        '目を閉じたまま、今日あった楽しいことをひとつだけ思い出してみて。'
        '最後の言葉まで近くで話しているから、安心して聞いていてね。';
    final prepared = _prepare(original, asmr: true);
    final requests = <http.Request>[];
    final transport = MockClient((request) async {
      requests.add(request);
      return http.Response.bytes(
        _mp3,
        200,
        headers: {'content-type': 'audio/mpeg'},
      );
    });
    addTearDown(transport.close);
    final result = await FishAudioClient(client: transport).synthesizeBytes(
      apiKey: 'local-test-key',
      referenceId: AppController.resolveFishAudioAsmrReferenceId(
        '',
        model: 's2-pro',
      ),
      text: prepared,
    );
    expect(result, _mp3);
    expect(requests, hasLength(1));
    final payload = jsonDecode(requests.single.body) as Map;
    expect(payload['reference_id'], _s2AsmrVoice);
    final sent = payload['text'] as String;
    expect(sent, startsWith(_s2WhisperCue));
    expect(sent, isNot(contains('[whispering]')));
    expect(
      sent,
      isNot(
        matches(
          RegExp(
            r'soft|panting|gasping|breath|inhale|exhale|\[relaxed\]|\[happy\]',
          ),
        ),
      ),
    );
    expect(_words(sent), original);
    expect(sent, prepared.replaceFirst('[whispering]', _s2WhisperCue));
    expect(requests.single.headers['model'], 's2-pro');
  });

  for (final model in ['s2-pro', 's2.1-pro', 's2.1-pro-free']) {
    test(
      'REST $model sends its unchanged model header and final descriptive whisper',
      () async {
        const original = '今日はここでゆっくり休もう。最後まで近くで話しているよ。';
        final prepared = _prepare(
          '[whispering]今日はここでゆっくり休もう。[whispering]最後まで近くで話しているよ。',
          asmr: true,
        );
        final requests = <http.Request>[];
        final transport = MockClient((request) async {
          requests.add(request);
          return http.Response.bytes(
            _mp3,
            200,
            headers: {'content-type': 'audio/mpeg'},
          );
        });
        addTearDown(transport.close);
        await FishAudioClient(client: transport).synthesizeBytes(
          apiKey: 'local-test-key',
          referenceId: AppController.resolveFishAudioAsmrReferenceId(
            '',
            model: model,
          ),
          text: prepared,
          model: model,
        );
        expect(requests, hasLength(1));
        expect(requests.single.headers['model'], model);
        final payload = jsonDecode(requests.single.body) as Map;
        expect(payload['reference_id'], _s2AsmrVoice);
        final sent = payload['text'] as String;
        expect(sent, '$_s2WhisperCue今日はここでゆっくり休もう。 最後まで近くで話しているよ。');
        expect(sent, isNot(contains('[whispering]')));
        expect(sent, isNot(contains('<whisper>')));
        expect(_words(sent), original);
      },
    );
  }

  for (final model in ['', 'provider-default', 'unknown-model']) {
    test(
      'REST unspecified or unknown model "$model" preserves generic whisper tags',
      () async {
        const text = '[whispering]こんにちは。';
        final requests = <http.Request>[];
        final transport = MockClient((request) async {
          requests.add(request);
          return http.Response.bytes(
            _mp3,
            200,
            headers: {'content-type': 'audio/mpeg'},
          );
        });
        addTearDown(transport.close);
        await FishAudioClient(client: transport).synthesizeBytes(
          apiKey: 'local-test-key',
          referenceId: AppController.defaultFishAudioReferenceId,
          text: text,
          model: model,
        );
        expect(requests, hasLength(1));
        expect(requests.single.headers['model'], model);
        expect((jsonDecode(requests.single.body) as Map)['text'], text);
      },
    );
  }

  for (final asmr in [false, true]) {
    test(
      'REST ${asmr ? 'ASMR density off' : 'ordinary voice'} does not invent delivery tags',
      () async {
        const plain = '明日も会おう。待っているよ。';
        final original = asmr ? '[soft tone]明日も会おう。[whispering]待っているよ。' : plain;
        final prepared = _prepare(
          original,
          asmr: asmr,
          density: asmr ? TtsCueDensity.off : TtsCueDensity.normal,
        );
        final requests = <http.Request>[];
        final transport = MockClient((request) async {
          requests.add(request);
          return http.Response.bytes(
            _mp3,
            200,
            headers: {'content-type': 'audio/mpeg'},
          );
        });
        addTearDown(transport.close);
        await FishAudioClient(client: transport).synthesizeBytes(
          apiKey: 'local-test-key',
          referenceId: AppController.defaultFishAudioReferenceId,
          text: prepared,
        );
        expect(requests, hasLength(1));
        final payload = jsonDecode(requests.single.body) as Map;
        expect(payload['reference_id'], _voice);
        expect(payload['text'], isNot(contains('[')));
        expect(_words(payload['text'] as String), plain);
      },
    );
  }
}
