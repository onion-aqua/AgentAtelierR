import 'package:flutter_test/flutter_test.dart';
import 'package:ryza_chat_mvp/src/audio_envelope.dart';
import 'package:ryza_chat_mvp/src/tts_duration_guard.dart';

void main() {
  test('short text rejects an unexpectedly long decoded clip', () {
    final envelope = AudioAmplitudeEnvelope.fromRms(
      List<double>.filled(500, 0.2),
    );

    final actual = ttsAudioDuration(envelope)!;
    expect(actual, const Duration(seconds: 10));
    expect(isTtsAudioOverlong('等一下。', actual), isTrue);
    expect(maximumTtsAudioDuration('等一下。'), const Duration(milliseconds: 4000));
  });

  test('longer text and ASMR allowance avoid false positives', () {
    final envelope = AudioAmplitudeEnvelope.fromRms(
      List<double>.filled(500, 0.2),
    );
    final actual = ttsAudioDuration(envelope)!;

    expect(
      isTtsAudioOverlong('这是一段较长的台词，用来说明正常语速下的完整语音内容，正常播放时不应该被判定为异常。', actual),
      isFalse,
    );
    expect(isTtsAudioOverlong('嗯。', const Duration(seconds: 4)), isFalse);
    expect(
      isTtsAudioOverlong('嗯。', const Duration(seconds: 5), asmr: true),
      isFalse,
    );
  });

  test('inline cues and whitespace do not inflate the text estimate', () {
    expect(ttsVisibleRuneCount('[happy][face:smile] 你好，世界。'), 6);
    expect(ttsAudioDuration(null), isNull);
  });
}
