import 'package:flutter_test/flutter_test.dart';
import 'package:ryza_chat_mvp/src/app_controller.dart';
import 'package:ryza_chat_mvp/src/chat_segments.dart';
import 'package:ryza_chat_mvp/src/fish_asmr_delivery.dart';
import 'package:ryza_chat_mvp/src/fish_drama3_tags.dart';
import 'package:ryza_chat_mvp/src/tts_text_normalizer.dart';

void main() {
  String words(String text) =>
      stripFishDrama3Tags(text).replaceAll(RegExp(r'\[[^\]]+\]|\s+'), '');

  test(
    'default ASMR whispers throughout even with emotions disabled and no cues',
    () {
      for (final drama3 in [false, true]) {
        final processed = applyFishEmotionIntensityPerSentence(
          '今晚下雨了。可以慢慢休息。',
          TtsEmotionIntensity.off,
          asmr: true,
          drama3: drama3,
        );
        expect(RegExp(r'\[whispering\]').allMatches(processed), hasLength(1));
        expect(processed, isNot(contains('[soft')));
        expect(processed, isNot(contains('relaxed')));
        expect(words(processed), '今晚下雨了。可以慢慢休息。');
        if (drama3) {
          final compiled = compileFishDrama3Text(processed);
          expect(compiled, startsWith('<whisper>'));
          expect(compiled, endsWith('</whisper>'));
          expect(words(compiled), '今晚下雨了。可以慢慢休息。');
        }
      }
    },
  );

  test(
    'delivery off remains untagged through planning and transport cleanup',
    () {
      for (final drama3 in [false, true]) {
        final processed = applyFishEmotionIntensityPerSentence(
          '[sad][whispering]晚安。[soft]明天见。',
          TtsEmotionIntensity.off,
          density: TtsCueDensity.off,
          asmr: true,
          drama3: drama3,
        );
        final cleaned = normalizeFishAudioSynthesisText(processed, asmr: true);
        expect(cleaned, isNot(contains('[')));
        expect(words(cleaned), '晚安。明天见。');
      }
    },
  );

  test(
    'planned soft and whisper aliases merge into one full-segment whisper',
    () {
      for (final drama3 in [false, true]) {
        final scoped = scopeFishAsmrDelivery(
          '[soft tone]你好。[whispering]这是秘密，[soft]剩下的话轻轻说。[near-whisper]再说一句。',
          drama3: drama3,
        );
        expect(scoped, '[whispering]你好。这是秘密，剩下的话轻轻说。再说一句。');
        expect(scopeFishAsmrDelivery(scoped, drama3: drama3), scoped);
        expect(words(scoped), '你好。这是秘密，剩下的话轻轻说。再说一句。');
        if (drama3) {
          expect(
            compileFishDrama3Text(scoped),
            '<whisper>你好。这是秘密，剩下的话轻轻说。再说一句。</whisper>',
          );
        }
      }
    },
  );

  test('long whispers keep one baseline without cutting words or resetting', () {
    final text = '字' * 45;
    final scoped = scopeFishAsmrDelivery('[whispering]$text');
    expect(scoped, '[whispering]$text');
    expect(words(scoped), text);
    const english =
        '[whispering]one two three four five six seven eight nine ten eleven twelve';
    final englishScoped = scopeFishAsmrDelivery(english);
    expect(englishScoped, english);
    expect(words(englishScoped), words(english));
  });

  test('ASMR breathing cues are removed instead of becoming whispers', () {
    final cleaned = normalizeFishAudioSynthesisText(
      '[breathy][panting]晚安。[inhale][sighing][soft breathy voice]慢慢来。',
      asmr: true,
    );
    expect(cleaned, '晚安。慢慢来。');
    expect(normalizeFishAudioSynthesisText(cleaned, asmr: true), cleaned);
  });

  test('ASMR normalizes saved official soft scopes to a full-segment whisper', () {
    final scoped = scopeFishAsmrDelivery(
      '<soft>The value is 3.14,</soft> <whisper>then say it quietly.</whisper> Good night.',
      drama3: true,
    );
    expect(
      scoped,
      '[whispering]The value is 3.14, then say it quietly. Good night.',
    );
    final compiled = compileFishDrama3Text(scoped);
    expect(
      compiled,
      '<whisper>The value is 3.14, then say it quietly. Good night.</whisper>',
    );
    expect(words(compiled), 'Thevalueis3.14,thensayitquietly.Goodnight.');
    expect(scopeFishAsmrDelivery(scoped, drama3: true), scoped);
  });

  test('normal mode retains its original explicit whisper behavior', () {
    const source = '[whispering]这是秘密。后面还是原来的处理方式。';
    expect(normalizeFishAudioSynthesisText(source), source);
    final normal = applyFishEmotionIntensityPerSentence(
      source,
      TtsEmotionIntensity.off,
    );
    expect(normal, contains('[whispering]'));
    expect(normal, isNot(contains('[soft')));
  });
}
