import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ryza_chat_mvp/src/app_localization.dart';
import 'package:ryza_chat_mvp/src/dialogue_language_guard.dart';

void main() {
  testWidgets(
    'hanging language correction fails within the overall budget without retry',
    (tester) async {
      final pending = Completer<String>();
      Object? failure;
      var calls = 0;
      ensureDialogueLanguage(
        text: '现在我们一起出发吧。',
        language: AppLanguage.japanese,
        complete: (_) {
          calls++;
          return pending.future;
        },
      ).then<void>(
        (_) => fail('A hanging correction must fail'),
        onError: (Object error) {
          failure = error;
        },
      );
      await tester.pump();
      await tester.pump(const Duration(seconds: 89));
      expect(failure, isNull);
      await tester.pump(const Duration(seconds: 1));
      expect(failure, isA<TimeoutException>());
      expect(calls, 1);
      pending.complete('{"corrections":[{"id":0,"text":"まだ中国語で返答しています。"}]}');
      await tester.pump();
      await tester.pump(const Duration(seconds: 90));
      expect(calls, 1);
    },
  );

  test('positive prose evidence distinguishes the supported languages', () {
    for (final (text, language) in [
      ('现在我们一起去炼金工房吧。', AppLanguage.chinese),
      ('ライザ、一緒にアトリエへ行こう！', AppLanguage.japanese),
      ('I will go to the atelier with you.', AppLanguage.english),
    ]) {
      expect(
        assessDialogueLanguage(text, language),
        DialogueLanguageVerdict.matches,
      );
      for (final other in AppLanguage.values.where(
        (value) => value != language,
      )) {
        expect(
          assessDialogueLanguage(text, other),
          DialogueLanguageVerdict.mismatch,
        );
      }
    }
  });

  test(
    'names, shared Han phrases, cues and quotations do not force a retry',
    () {
      for (final text in [
        'ライザ',
        'クラウディア',
        '莱莎',
        '了解。',
        'Ryza Stout',
        '…',
        '[happy][whispering]',
      ]) {
        for (final language in AppLanguage.values) {
          expect(
            assessDialogueLanguage(text, language),
            isNot(DialogueLanguageVerdict.mismatch),
            reason: '$text/$language',
          );
        }
      }
      expect(
        assessDialogueLanguage('我说过「ありがとう」，现在我们可以出发了。', AppLanguage.chinese),
        DialogueLanguageVerdict.matches,
      );
      expect(
        assessDialogueLanguage('我喜欢ライザ，现在我们一起出发吧。', AppLanguage.chinese),
        DialogueLanguageVerdict.matches,
      );
      expect(
        assessDialogueLanguage('「ありがとう、ライザ！」', AppLanguage.chinese),
        DialogueLanguageVerdict.mismatch,
      );
      expect(
        assessDialogueLanguage(
          'Ryza: I will go with you.',
          AppLanguage.english,
        ),
        DialogueLanguageVerdict.matches,
      );
    },
  );

  test('valid text and ambiguous brief replies never add requests', () async {
    var calls = 0;
    for (final text in ['了解。', '今日は良い天気だね！']) {
      expect(
        await ensureDialogueLanguage(
          text: text,
          language: AppLanguage.japanese,
          complete: (_) async {
            calls++;
            return '';
          },
        ),
        text,
      );
    }
    expect(calls, 0);
  });

  test(
    'mixed-role repair targets only wrong beats and preserves NPC and cues',
    () async {
      var calls = 0;
      final result = await ensureAssistantReplyLanguages(
        source: '旁白：现在我们一起走进工房。\n苏菲：[happy]现在我们一起出发吧。\n角色[klaudia]：また会えると嬉しいです。\n译文：我们可以一起见面。',
        replyLanguage: AppLanguage.japanese,
        narratorLanguage: AppLanguage.chinese,
        inlineTranslationLanguage: TranslationLanguage.chinese,
        primaryCharacterId: 'sophie',
        complete: (messages) async {
          calls++;
          final lines =
              (jsonDecode(messages.last['content']!) as Map)['lines'] as List;
          expect(lines, hasLength(1));
          expect(lines.single['id'], 1);
          expect(lines.single['target_language'], 'Japanese');
          return '{"corrections":[{"id":1,"text":"一緒に出発しよう！"}]}';
        },
      );
      expect(calls, 1);
      expect(
        result,
        '旁白：现在我们一起走进工房。\n苏菲：[happy]一緒に出発しよう！\n角色[klaudia]：また会えると嬉しいです。\n译文：我们可以一起见面。',
      );
    },
  );

  test('a still-wrong repair and injected role/control markup fail after one request', () async {
    for (final repair in [
      '现在我们一起出发吧。',
      '莱莎：一緒に行こう！',
      '<think>private</think>一緒に行こう！',
      '[action:walk]一緒に行こう！',
    ]) {
      var calls = 0;
      await expectLater(
        ensureDialogueLanguage(
          text: '现在我们一起出发吧。',
          language: AppLanguage.japanese,
          complete: (_) async {
            calls++;
            return jsonEncode({
              'corrections': [
                {'id': 0, 'text': repair},
              ],
            });
          },
        ),
        throwsA(isA<DialogueLanguageException>()),
      );
      expect(calls, 1);
    }
  });

  test(
    'whole-message correction preserves multiple paragraphs for NPC chat',
    () async {
      var calls = 0;
      const fixed = '一緒に出発しよう！\n\nアトリエで待っているね。';
      final result = await ensureDialogueLanguage(
        text: '现在我们一起出发吧。\n\n我会在炼金工房等你。',
        language: AppLanguage.japanese,
        complete: (_) async {
          calls++;
          return jsonEncode({
            'corrections': [
              {'id': 0, 'text': fixed},
            ],
          });
        },
      );
      expect(result, fixed);
      expect(calls, 1);
    },
  );

  test(
    'unrequested inline translations are removed without a new request',
    () async {
      var calls = 0;
      final result = await ensureAssistantReplyLanguages(
        source: '莱莎：一緒に出発しよう！\n译文：我们一起出发吧。\n旁白：她挥了挥手。',
        replyLanguage: AppLanguage.japanese,
        narratorLanguage: AppLanguage.chinese,
        inlineTranslationLanguage: TranslationLanguage.none,
        complete: (_) async {
          calls++;
          return '';
        },
      );
      expect(result, '莱莎：一緒に出発しよう！\n旁白：她挥了挥手。');
      expect(calls, 0);
    },
  );

  test(
    'inline translation coverage follows every speaker and skips narration',
    () {
      expect(
        hasCompleteInlineTranslations('旁白：天亮了。\n莱莎：おはよう！\n译文：早安。\n旁白：她挥手。'),
        isTrue,
      );
      expect(
        hasCompleteInlineTranslations('莱莎：おはよう！\n旁白：她挥手。\n译文：早安。'),
        isFalse,
      );
      expect(
        hasCompleteInlineTranslations('莱莎：おはよう！\n译文：早安。\n角色[klaudia]：こんにちは。'),
        isFalse,
      );
    },
  );
}
