import 'package:flutter_test/flutter_test.dart';
import 'package:ryza_chat_mvp/src/tts_text_normalizer.dart';

void main() {
  test('compresses repeated punctuation without changing regular text', () {
    expect(compressRepeatedTtsPunctuation('等一下......真的！！！好？'), '等一下...真的！！好？');
    expect(compressRepeatedTtsPunctuation('普通句子。'), '普通句子。');
  });

  test('removes only small tsu after ellipsis for Fish Audio', () {
    expect(normalizeFishAudioText('あ……っ、待って！'), 'あ……、待って！');
    expect(normalizeFishAudioText('あ…っ もっと'), 'あ… もっと');
    expect(normalizeFishAudioText('あ...っ'), 'あ...');
    expect(
      normalizeFishAudioText('あ…[short pause] っ、待って'),
      'あ…[short pause] 、待って',
    );
    expect(normalizeFishAudioText('待って、もっとゆっくり。'), '待って、もっとゆっくり。');
    expect(normalizeFishAudioText('……って言ったよね。'), '……って言ったよね。');
    expect(
      normalizeFishAudioText('……[whispering]って言った。'),
      '……[whispering]って言った。',
    );
    expect(normalizeFishAudioText('あ……っ[short pause]。'), 'あ……[short pause]。');
  });

  test('Fish transport removes performed breathing without changing words', () {
    expect(
      normalizeFishAudioSynthesisText(
        '[breathy][panting]こんにちは。[inhale]少し休もう。[exhale][sighing]',
      ),
      'こんにちは。少し休もう。',
    );
    expect(
      normalizeFishAudioSynthesisText('息を吸って、ゆっくり話そう。ふぅ。'),
      '息を吸って、ゆっくり話そう。ふぅ。',
    );
  });

  test('ASMR keeps one whisper baseline and never promotes breathing', () {
    final text = normalizeFishAudioSynthesisText(
      '[very breathy voice][unvoiced whispering]おやすみ。[long pause][inhale]明日も会おう。[whispering][pause]',
      asmr: true,
    );
    expect(text, '[whispering]おやすみ。[short pause]明日も会おう。');
    expect(normalizeFishAudioSynthesisText(text, asmr: true), text);
  });

  test('compound emotion keeps its meaning without breath timing', () {
    expect(
      normalizeFishAudioSynthesisText(
        '[intensely sad, expressed through very quiet whispering, with emotional phrasing and breath timing while keeping the voice hushed]大丈夫。',
      ),
      '[intensely sad][whispering]大丈夫。',
    );
    expect(
      normalizeFishAudioSynthesisText('[excited][emphasis]できた！'),
      '[excited][emphasis]できた！',
    );
  });

  test(
    'normalization caps punctuation idempotently and preserves gemination',
    () {
      const text = 'あ………っ、待って！！！！……';
      final normalized = normalizeFishAudioSynthesisText(text);
      expect(normalized, 'あ……、待って！……');
      expect(normalizeFishAudioSynthesisText(normalized), normalized);
    },
  );

  test(
    'localized breathing directions are removed but dialogue is preserved',
    () {
      expect(
        normalizeFishAudioSynthesisText('[气声][吸氣]慢慢呼吸。[叹气][息遣い]息を吸って。[ため息]'),
        '慢慢呼吸。息を吸って。',
      );
    },
  );

  test(
    'repeated cues stay bounded and normalization has no cross-clip state',
    () {
      final text = '${'[whispering][panting][long pause]' * 80}おやすみ。';
      final normalized = normalizeFishAudioSynthesisText(text, asmr: true);
      expect(RegExp(r'\[whispering\]').allMatches(normalized), hasLength(1));
      expect(RegExp(r'\[short pause\]').allMatches(normalized), hasLength(1));
      expect(normalized, contains('おやすみ。'));
      expect(
        normalizeFishAudioSynthesisText(normalized, asmr: true),
        normalized,
      );
      expect(
        normalizeFishAudioSynthesisText('[whispering]また明日。', asmr: true),
        '[whispering]また明日。',
      );
    },
  );
}
