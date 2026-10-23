import 'package:flutter_test/flutter_test.dart';
import 'package:ryza_chat_mvp/src/fish_s2_tags.dart';

void main() {
  const whisper =
      '[whispering intimately into the microphone, hushed and clearly articulated throughout]';
  String spoken(String text) =>
      text.replaceAll(RegExp(r'\[[^\[\]\r\n]+\]'), '');

  test('only the explicit official S2 identifiers enable this format', () {
    for (final model in ['s2-pro', 's2.1-pro', 's2.1-pro-free', ' S2.1-PRO ']) {
      expect(isFishS2Model(model), isTrue, reason: model);
    }
    for (final model in <String?>[
      null,
      '',
      's2.1',
      's2',
      'speech-1.5',
      'drama-3',
      's2-pro-custom',
      'custom-s2.1-pro',
    ]) {
      expect(isFishS2Model(model), isFalse, reason: '$model');
    }
  });

  test('explicit whisper aliases become one stronger S2 direction', () {
    for (final cue in [
      'whisper',
      'whispering',
      'unvoiced whispering',
      'near-whisper',
      ' WHISPERING ',
      'whispering intimately into the microphone',
      'whispering, hushed throughout',
      'whispering with clear connected words',
    ]) {
      final result = compileFishS2Text('[$cue]晚安。明天见。');
      expect(result, '$whisper晚安。明天见。', reason: cue);
      expect(compileFishS2Text(result), result);
    }
  });

  test(
    'long multi-sentence ASMR receives a single cue rather than repetition',
    () {
      final text = '字' * 220;
      final input =
          '[whispering]$text。再说一句。[soft tone]这段也保留。[near-whisper]最后一句。';
      final result = compileFishS2Text(input);
      expect(RegExp(r'\[whispering[^\]]*\]').allMatches(result), hasLength(1));
      expect(result, '$whisper$text。再说一句。[soft tone]这段也保留。最后一句。');
      expect(spoken(result), spoken(input));
      expect(compileFishS2Text(result), result);
    },
  );

  test('plain text and delivery-disabled text do not gain ASMR controls', () {
    for (final text in [
      '晚安。明天见。',
      'Someone said whispering, but this is ordinary dialogue.',
      '[sad]我有一点难过。[short pause]明天再聊。',
      '<whisper>Drama 3 stays separate.</whisper>',
      '[soft]轻轻说。',
      '[not a whisper]保留未知标签。',
      '[whispering_custom]未来标签。',
    ]) {
      expect(compileFishS2Text(text), text);
    }
  });

  test(
    'emotions, local accents, whitespace and multilingual words remain exact',
    () {
      const input =
          '[sad]  [whispering]大丈夫。\n'
          '[emphasis]Keep 3.14, 1,000 and punctuation. [short pause] 你好！'
          '[near-whisper]またね。';
      final result = compileFishS2Text(input);
      expect(result, contains('[sad]  $whisper'));
      expect(result, contains('[emphasis]'));
      expect(result, contains('[short pause]'));
      expect(spoken(result), spoken(input));
      expect(result, isNot(matches(RegExp(r'breathy|inhale|exhale|panting'))));
      expect(compileFishS2Text(result), result);
    },
  );
}
