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
  });
}
