import 'package:flutter_test/flutter_test.dart';
import 'package:ryza_chat_mvp/src/fish_mcp_sentence_timing.dart';
import 'package:ryza_chat_mvp/src/fish_drama3_tags.dart';
import 'package:ryza_chat_mvp/src/fish_s2_tags.dart';

void main() {
  test('pause setting clamps invalid and imported values safely', () {
    for (final value in <num?>[
      null,
      double.nan,
      double.infinity,
      -double.infinity,
    ]) {
      expect(clampFishMcpSentencePauseMs(value), 220);
    }
    expect(clampFishMcpSentencePauseMs(-40), 0);
    expect(clampFishMcpSentencePauseMs(219.7), 220);
    expect(clampFishMcpSentencePauseMs(900), 800);
  });

  test(
    'configured pause tiers preserve controls and disable only automatic cues',
    () {
      for (final (milliseconds, cue) in [
        (0, ''),
        (220, '[short pause]'),
        (399, '[short pause]'),
        (400, '[pause]'),
        (699, '[pause]'),
        (700, '[long pause]'),
        (800, '[long pause]'),
      ]) {
        final text = addFishMcpSentencePauses(
          '[whispering]你好。晚安。',
          sentencePauseMs: milliseconds,
        );
        expect(text, '[whispering]你好。$cue晚安。');
        expect(
          addFishMcpSentencePauses(text, sentencePauseMs: milliseconds),
          text,
        );
        expect(compileFishDrama3Text(text), '<whisper>你好。$cue晚安。</whisper>');
        expect(compileFishS2Text(text), '$fishS2WhisperCue你好。$cue晚安。');
        const explicit = '你好。[pause]晚安。';
        expect(
          addFishMcpSentencePauses(explicit, sentencePauseMs: milliseconds),
          explicit,
        );
        final bounded = addFishMcpSentencePauses(
          '一句话。' * 30,
          sentencePauseMs: milliseconds,
        );
        expect(
          RegExp(r'\[(?:(?:short|long) )?pause\]').allMatches(bounded),
          hasLength(milliseconds == 0 ? 0 : 6),
        );
      }
    },
  );

  test('spaces adjacent Chinese Japanese and English sentences', () {
    for (final (source, expected) in [
      ('你好。慢慢来！我在这里。', '你好。[short pause]慢慢来！[short pause]我在这里。'),
      ('大丈夫？ここにいるよ。おやすみ。', '大丈夫？[short pause]ここにいるよ。[short pause]おやすみ。'),
      (
        'Hello. Stay here! Ready?',
        'Hello. [short pause]Stay here! [short pause]Ready?',
      ),
      ('先放松\n再慢慢说。', '先放松\n[short pause]再慢慢说。'),
    ]) {
      expect(addFishMcpSentencePauses(source), expected);
    }
  });

  test('punctuation quotes and explicit pauses do not double up', () {
    expect(
      addFishMcpSentencePauses('「待って。」次へ！？\n\nおやすみ。'),
      '「待って。」[short pause]次へ！？\n\n[short pause]おやすみ。',
    );
    for (final tag in ['[short pause]', '[pause]', '[long pause]']) {
      final input = '你好。[happy]$tag 慢慢说。';
      expect(addFishMcpSentencePauses(input), input);
    }
    expect(addFishMcpSentencePauses('你好，慢慢来、再休息；晚安。'), '你好，慢慢来、再休息；晚安。');
  });

  test('numbers URLs abbreviations and tag contents are never split', () {
    const input =
        '[happy. still happy]Dr. Ryza uses 3.14 and v1.0.4 at '
        'https://example.com/a.b. Stay with Mr. Smith in the U.S. today.';
    expect(addFishMcpSentencePauses(input), input);
    expect(
      addFishMcpSentencePauses('Visit example.com today. Good night.'),
      'Visit example.com today. [short pause]Good night.',
    );
    expect(
      addFishMcpSentencePauses('J. K. Rowling wrote this. Next sentence.'),
      'J. K. Rowling wrote this. [short pause]Next sentence.',
    );
  });

  test('next sentence may start with a quote without moving its text', () {
    for (final (source, expected) in [
      ('你好。「慢慢说。」', '你好。[short pause]「慢慢说。」'),
      ('Hello. “Stay here.”', 'Hello. [short pause]“Stay here.”'),
      ('Hello. "Stay here."', 'Hello. [short pause]"Stay here."'),
    ]) {
      expect(addFishMcpSentencePauses(source), expected);
      expect(addFishMcpSentencePauses(expected), expected);
    }
  });

  test(
    'no leading trailing or control-only pause; processing is idempotent',
    () {
      for (final input in ['', '[happy]', '[whispering]你好。', '！？你好。\n']) {
        expect(addFishMcpSentencePauses(input), input);
      }
      final result = addFishMcpSentencePauses('<whisper>你好。再见。</whisper>');
      expect(result, '<whisper>你好。[short pause]再见。</whisper>');
      expect(addFishMcpSentencePauses(result), result);
      final long = addFishMcpSentencePauses('一句话。' * 30);
      expect(RegExp(r'\[short pause\]').allMatches(long), hasLength(6));
      expect(long.replaceAll('[short pause]', ''), '一句话。' * 30);
      expect(addFishMcpSentencePauses(long), long);
    },
  );

  test('model compilation keeps pauses without adding breathing effects', () {
    final text = addFishMcpSentencePauses('[whispering]你好。晚安。');
    expect(
      compileFishDrama3Text(text),
      '<whisper>你好。[short pause]晚安。</whisper>',
    );
    expect(compileFishS2Text(text), '$fishS2WhisperCue你好。[short pause]晚安。');
    expect(fishMcpClipPause.inMilliseconds, 220);
  });
}
