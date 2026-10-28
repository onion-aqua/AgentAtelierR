import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ryza_chat_mvp/src/app_localization.dart';
import 'package:ryza_chat_mvp/src/continuous_asmr_script.dart';
import 'package:ryza_chat_mvp/src/dialogue_language_guard.dart';

const _japanese = '今日はゆっくり休もうね。一緒に静かな雨の音を聞いていよう。';
const _chinese = '现在我们一起慢慢休息吧。你可以听听窗边轻柔的雨声。';
const _english = 'You can rest here with me. We will listen to the soft rain.';

AsmrLanguagePolicy _policy({
  AppLanguage reply = AppLanguage.japanese,
  TranslationLanguage translation = TranslationLanguage.chinese,
  bool independent = true,
}) => AsmrLanguagePolicy(
  replyLanguage: reply,
  translationLanguage: translation,
  independentTranslation: independent,
);

void _current() {}

Future<String> _noCompletion(List<Map<String, String>> messages) async {
  fail('This valid ASMR text must not add a completion request.');
}

List<dynamic> _requestLines(List<Map<String, String>> messages) =>
    (jsonDecode(
          messages.firstWhere(
            (message) => message['role'] == 'user',
          )['content']!,
        ) as Map)['lines']
        as List<dynamic>;

String _translationsFor(
  List<Map<String, String>> messages,
  String translation,
) => jsonEncode({
  'translations': [
    for (final line in _requestLines(messages))
      {'id': line['id'], 'text': translation},
  ],
});

void main() {
  group('ASMR language policy', () {
    test(
      'translation none and same language disable both translation paths',
      () {
        for (final reply in AppLanguage.values) {
          final sameTranslation = switch (reply) {
            AppLanguage.chinese => TranslationLanguage.chinese,
            AppLanguage.english => TranslationLanguage.english,
            AppLanguage.japanese => TranslationLanguage.japanese,
          };
          for (final translation in [
            TranslationLanguage.none,
            sameTranslation,
          ]) {
            for (final independent in [false, true]) {
              final policy = _policy(
                reply: reply,
                translation: translation,
                independent: independent,
              );
              expect(policy.translationTarget, isNull);
              expect(policy.translates, isFalse);
              expect(policy.translatesIndependently, isFalse);
            }
          }
        }
      },
    );

    test('the independent switch selects the translation route', () {
      for (final independent in [false, true]) {
        final policy = _policy(independent: independent);
        expect(policy.translationTarget, AppLanguage.chinese);
        expect(policy.translates, isTrue);
        expect(policy.translatesIndependently, independent);
        expect(policy.promptInstruction, contains('Japanese'));
      }
    });
  });

  group('ASMR spoken script', () {
    test(
      'inline Japanese translation filters breath artifacts before display',
      () async {
        final segments = await prepareAsmrScript(
          response: jsonEncode({
            'segments': [
              {'text': _chinese, 'translation': 'あ……っ、$_japanese'},
            ],
          }),
          policy: _policy(
            reply: AppLanguage.chinese,
            translation: TranslationLanguage.japanese,
            independent: false,
          ),
          complete: _noCompletion,
          ensureCurrent: _current,
        );
        expect(segments.single.translation, 'あ……、$_japanese');
      },
    );

    test(
      'valid Chinese, Japanese and English do not request language repair',
      () async {
        for (final (language, text) in [
          (AppLanguage.chinese, _chinese),
          (AppLanguage.japanese, _japanese),
          (AppLanguage.english, _english),
        ]) {
          final segments = await prepareAsmrScript(
            response: '[whispering]$text',
            policy: _policy(
              reply: language,
              translation: TranslationLanguage.none,
            ),
            complete: _noCompletion,
            ensureCurrent: _current,
          );
          expect(
            segments.map((segment) => segment.text).join(),
            '[whispering]$text',
          );
          expect(
            segments.every((segment) => segment.translation == null),
            isTrue,
          );
        }
      },
    );

    test(
      'narration and dialogue share the spoken language and lose role prefixes',
      () async {
        final segments = await prepareAsmrScript(
          response: '旁白：[whispering]彼女はそっと窓を開けた。\n莱莎：$_japanese\n译文：$_chinese',
          policy: _policy(),
          complete: _noCompletion,
          ensureCurrent: _current,
        );
        final speech = segments.map((segment) => segment.text).join();
        expect(speech, contains('彼女はそっと窓を開けた。'));
        expect(speech, contains(_japanese));
        expect(speech, contains('[whispering]'));
        expect(speech, isNot(contains('旁白：')));
        expect(speech, isNot(contains('莱莎：')));
        expect(speech, isNot(contains(_chinese)));
        expect(
          segments.every((segment) => segment.translation == null),
          isTrue,
        );
      },
    );

    test(
      'translation-disabled text drops accidental translations before TTS',
      () async {
        for (final independent in [false, true]) {
          final segments = await prepareAsmrScript(
            response: '莱莎：[whispering]$_japanese\n译文：$_chinese',
            policy: _policy(
              translation: TranslationLanguage.none,
              independent: independent,
            ),
            complete: _noCompletion,
            ensureCurrent: _current,
          );
          expect(
            segments.map((segment) => segment.text).join(),
            '[whispering]$_japanese',
          );
          expect(
            segments.every((segment) => segment.translation == null),
            isTrue,
          );
        }
      },
    );

    test('unexpected JSON keeps only original speech when inline translation is off', () async {
      for (final policy in [
        _policy(),
        _policy(translation: TranslationLanguage.none, independent: false),
      ]) {
        final segments = await prepareAsmrScript(
          response: jsonEncode({
            'segments': [
              {'text': '[whispering]$_japanese', 'translation': _chinese},
            ],
          }),
          policy: policy,
          complete: _noCompletion,
          ensureCurrent: _current,
        );
        expect(
          segments.map((segment) => segment.text).join(),
          '[whispering]$_japanese',
        );
        expect(
          segments.every((segment) => segment.translation == null),
          isTrue,
        );
      }
    });

    test(
      'malformed unexpected JSON is never treated as spoken prose',
      () async {
        for (final response in [
          '{"segments":[{"text":',
          '{"segments":[{"translation":"$_chinese"}]}',
        ]) {
          await expectLater(
            prepareAsmrScript(
              response: response,
              policy: _policy(translation: TranslationLanguage.none),
              complete: _noCompletion,
              ensureCurrent: _current,
            ),
            throwsA(isA<FormatException>()),
          );
        }
      },
    );

    test('wrong-language narration is corrected once while preserving delivery cues', () async {
      var calls = 0;
      final segments = await prepareAsmrScript(
        response: '旁白：[whispering]现在我们一起慢慢休息吧，你可以听听窗边轻柔的雨声。',
        policy: _policy(translation: TranslationLanguage.none),
        complete: (messages) async {
          calls++;
          final lines = _requestLines(messages);
          expect(lines, hasLength(1));
          expect(lines.single['target_language'], 'Japanese');
          return jsonEncode({
            'corrections': [
              {'id': lines.single['id'], 'text': _japanese},
            ],
          });
        },
        ensureCurrent: _current,
      );
      expect(calls, 1);
      expect(
        segments.map((segment) => segment.text).join(),
        '[whispering]$_japanese',
      );
    });

    test(
      'persistent wrong-language prose blocks TTS after one repair',
      () async {
        var calls = 0;
        await expectLater(
          prepareAsmrScript(
            response: '[whispering]$_chinese',
            policy: _policy(translation: TranslationLanguage.none),
            complete: (messages) async {
              calls++;
              return jsonEncode({
                'corrections': [
                  {
                    'id': _requestLines(messages).single['id'],
                    'text': _chinese,
                  },
                ],
              });
            },
            ensureCurrent: _current,
          ),
          throwsA(isA<DialogueLanguageException>()),
        );
        expect(calls, 1);
      },
    );

    test(
      'long spoken scripts retain content and bounded audio segments',
      () async {
        final text = '[whispering]${_japanese * 12}';
        final segments = await prepareAsmrScript(
          response: text,
          policy: _policy(translation: TranslationLanguage.none),
          complete: _noCompletion,
          ensureCurrent: _current,
        );
        expect(segments.map((segment) => segment.text).join(), text);
        expect(segments.every((segment) => segment.text.length <= 96), isTrue);
        expect(segments.last.pauseAfter, Duration.zero);
      },
    );

    test(
      'cancellation after repair prevents a prepared script from escaping',
      () async {
        var cancelled = false;
        var calls = 0;
        await expectLater(
          prepareAsmrScript(
            response: _chinese,
            policy: _policy(translation: TranslationLanguage.none),
            complete: (messages) async {
              calls++;
              cancelled = true;
              return jsonEncode({
                'corrections': [
                  {
                    'id': _requestLines(messages).single['id'],
                    'text': _japanese,
                  },
                ],
              });
            },
            ensureCurrent: () {
              if (cancelled) throw StateError('cancelled');
            },
          ),
          throwsA(isA<StateError>()),
        );
        expect(calls, 1);
      },
    );
  });

  group('ASMR inline translation', () {
    test('Chinese speech can use Japanese subtitles in inline mode', () async {
      final segments = await prepareAsmrScript(
        response: jsonEncode({
          'segments': [
            {'text': _chinese, 'translation': _japanese},
          ],
        }),
        policy: _policy(
          reply: AppLanguage.chinese,
          translation: TranslationLanguage.japanese,
          independent: false,
        ),
        complete: _noCompletion,
        ensureCurrent: _current,
      );
      expect(segments.single.text, _chinese);
      expect(segments.single.translation, _japanese);
    });

    test('inline source and translation are separated before TTS', () async {
      final segments = await prepareAsmrScript(
        response: jsonEncode({
          'segments': [
            {'text': '[whispering]$_japanese', 'translation': _chinese},
            {'text': '[breathy]少しずつ肩の力を抜いてね。', 'translation': '现在你可以慢慢放松肩膀。'},
          ],
        }),
        policy: _policy(independent: false),
        complete: _noCompletion,
        ensureCurrent: _current,
      );
      expect(segments, hasLength(2));
      expect(segments.first.text, '[whispering]$_japanese');
      expect(segments.first.translation, _chinese);
      expect(segments.last.translation, '现在你可以慢慢放松肩膀。');
      final tts = segments.map((segment) => segment.text).join();
      expect(tts, isNot(contains(_chinese)));
      expect(tts, isNot(contains('"translation"')));
    });

    test('missing inline structure gets one bounded format recovery', () async {
      var calls = 0;
      final segments = await prepareAsmrScript(
        response: '莱莎：$_japanese\n译文：$_chinese',
        policy: _policy(independent: false),
        complete: (_) async {
          calls++;
          return jsonEncode({
            'segments': [
              {'text': _japanese, 'translation': _chinese},
            ],
          });
        },
        ensureCurrent: _current,
      );
      expect(calls, 1);
      expect(segments.single.text, _japanese);
      expect(segments.single.translation, _chinese);
    });

    test(
      'persistent missing inline structure is rejected after one recovery',
      () async {
        var calls = 0;
        await expectLater(
          prepareAsmrScript(
            response: _japanese,
            policy: _policy(independent: false),
            complete: (_) async {
              calls++;
              return _japanese;
            },
            ensureCurrent: _current,
          ),
          throwsA(isA<FormatException>()),
        );
        expect(calls, 1);
      },
    );

    test(
      'same-language inline translations never enter speech or display',
      () async {
        final segments = await prepareAsmrScript(
          response: '莱莎：[whispering]$_chinese\n译文：$_chinese',
          policy: _policy(reply: AppLanguage.chinese, independent: false),
          complete: _noCompletion,
          ensureCurrent: _current,
        );
        expect(
          segments.map((segment) => segment.text).join(),
          '[whispering]$_chinese',
        );
        expect(
          segments.every((segment) => segment.translation == null),
          isTrue,
        );
      },
    );

    test(
      'copied inline translation is repaired without changing spoken text',
      () async {
        var calls = 0;
        final segments = await prepareAsmrScript(
          response: jsonEncode({
            'segments': [
              {'text': '[whispering]$_japanese', 'translation': _japanese},
            ],
          }),
          policy: _policy(independent: false),
          complete: (messages) async {
            calls++;
            final lines = _requestLines(messages);
            expect(lines, hasLength(1));
            expect(lines.single['text'], _japanese);
            return _translationsFor(messages, _chinese);
          },
          ensureCurrent: _current,
        );
        expect(calls, 1);
        expect(segments.single.text, '[whispering]$_japanese');
        expect(segments.single.translation, _chinese);
      },
    );

    for (final malformed in ['duplicate ids', 'missing ids', 'copied source']) {
      test('inline $malformed fails after one translation repair', () async {
        var calls = 0;
        await expectLater(
          prepareAsmrScript(
            response: jsonEncode({
              'segments': [
                {'text': _japanese, 'translation': _japanese},
                {'text': _japanese, 'translation': _japanese},
              ],
            }),
            policy: _policy(independent: false),
            complete: (messages) async {
              calls++;
              final id = _requestLines(messages).first['id'];
              return switch (malformed) {
                'duplicate ids' => jsonEncode({
                  'translations': [
                    {'id': id, 'text': _chinese},
                    {'id': id, 'text': _chinese},
                  ],
                }),
                'missing ids' => jsonEncode({
                  'translations': [
                    {'id': id, 'text': _chinese},
                  ],
                }),
                _ => _translationsFor(messages, _japanese),
              };
            },
            ensureCurrent: _current,
          ),
          throwsA(isA<FormatException>()),
        );
        expect(calls, 1);
      });
    }

    test('cancellation during format recovery stops before validation or another request', () async {
      var cancelled = false;
      var calls = 0;
      await expectLater(
        prepareAsmrScript(
          response: _japanese,
          policy: _policy(independent: false),
          complete: (_) async {
            calls++;
            cancelled = true;
            return 'not JSON';
          },
          ensureCurrent: () {
            if (cancelled) throw StateError('cancelled');
          },
        ),
        throwsA(isA<StateError>()),
      );
      expect(calls, 1);
    });
  });

  group('ASMR independent translation', () {
    const segments = [
      AsmrSpeechSegment('[whispering]$_japanese', Duration(milliseconds: 320)),
      AsmrSpeechSegment('少しずつ肩の力を抜いてね。', Duration.zero),
    ];

    test(
      'Chinese speech can use Japanese subtitles in independent mode',
      () async {
        var calls = 0;
        final translations = await translateAsmrSegments(
          segments: const [AsmrSpeechSegment(_chinese, Duration.zero)],
          policy: _policy(
            reply: AppLanguage.chinese,
            translation: TranslationLanguage.japanese,
          ),
          complete: (messages) async {
            calls++;
            expect(_requestLines(messages).single['text'], _chinese);
            expect(messages.first['content'], contains('Japanese'));
            return _translationsFor(messages, _japanese);
          },
          ensureCurrent: _current,
        );
        expect(calls, 1);
        expect(translations, {0: _japanese});
      },
    );

    test(
      'no independent request when disabled, translation none or same language',
      () async {
        for (final policy in [
          _policy(independent: false),
          _policy(translation: TranslationLanguage.none),
          _policy(translation: TranslationLanguage.japanese),
        ]) {
          expect(
            await translateAsmrSegments(
              segments: segments,
              policy: policy,
              complete: _noCompletion,
              ensureCurrent: _current,
            ),
            isEmpty,
          );
        }
      },
    );

    test(
      'independent translation returns an index map without delivery cues',
      () async {
        var calls = 0;
        final translations = await translateAsmrSegments(
          segments: segments,
          policy: _policy(),
          complete: (messages) async {
            calls++;
            final lines = _requestLines(messages);
            expect(lines, hasLength(2));
            expect(lines.first['text'], _japanese);
            expect(lines.first['text'], isNot(contains('[whispering]')));
            return _translationsFor(messages, _chinese);
          },
          ensureCurrent: _current,
        );
        expect(calls, 1);
        expect(translations, {0: _chinese, 1: _chinese});
        expect(segments.first.text, '[whispering]$_japanese');
      },
    );

    test('a wrong-language independent result is repaired once', () async {
      var calls = 0;
      final translations = await translateAsmrSegments(
        segments: const [AsmrSpeechSegment(_japanese, Duration.zero)],
        policy: _policy(),
        complete: (messages) async {
          calls++;
          return _translationsFor(messages, calls == 1 ? _japanese : _chinese);
        },
        ensureCurrent: _current,
      );
      expect(calls, 2);
      expect(translations, {0: _chinese});
    });

    for (final malformed in ['duplicate ids', 'missing ids', 'copied source']) {
      test('$malformed cannot produce a misleading translation', () async {
        var calls = 0;
        await expectLater(
          translateAsmrSegments(
            segments: segments,
            policy: _policy(),
            complete: (messages) async {
              calls++;
              final lines = _requestLines(messages);
              final id = lines.first['id'];
              return switch (malformed) {
                'duplicate ids' => jsonEncode({
                  'translations': [
                    {'id': id, 'text': _chinese},
                    {'id': id, 'text': _chinese},
                  ],
                }),
                'missing ids' => jsonEncode({
                  'translations': [
                    {'id': id, 'text': _chinese},
                  ],
                }),
                _ => _translationsFor(messages, _japanese),
              };
            },
            ensureCurrent: _current,
          ),
          throwsA(isA<FormatException>()),
        );
        expect(calls, 2);
      });
    }

    test(
      'long scripts translate in bounded batches without losing global indices',
      () async {
        final longSegments = [
          for (var i = 0; i < 13; i++)
            AsmrSpeechSegment('$_japanese$i', Duration.zero),
        ];
        var calls = 0;
        final translations = await translateAsmrSegments(
          segments: longSegments,
          policy: _policy(),
          complete: (messages) async {
            calls++;
            expect(_requestLines(messages).length, lessThanOrEqualTo(10));
            return _translationsFor(messages, _chinese);
          },
          ensureCurrent: _current,
        );
        expect(calls, 2);
        expect(translations.keys, orderedEquals(List.generate(13, (i) => i)));
        expect(translations.values, everyElement(_chinese));
      },
    );

    test(
      'cancellation after one batch prevents the next translation request',
      () async {
        var cancelled = false;
        var calls = 0;
        await expectLater(
          translateAsmrSegments(
            segments: [
              for (var i = 0; i < 11; i++)
                const AsmrSpeechSegment(_japanese, Duration.zero),
            ],
            policy: _policy(),
            complete: (messages) async {
              calls++;
              cancelled = true;
              return _translationsFor(messages, _chinese);
            },
            ensureCurrent: () {
              if (cancelled) throw StateError('cancelled');
            },
          ),
          throwsA(isA<StateError>()),
        );
        expect(calls, 1);
      },
    );
  });
}
