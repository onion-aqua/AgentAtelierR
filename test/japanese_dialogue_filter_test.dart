import 'package:flutter_test/flutter_test.dart';
import 'package:ryza_chat_mvp/src/chat_segments.dart';
import 'package:ryza_chat_mvp/src/japanese_dialogue_filter.dart';

void main() {
  test(
    'removes standalone breath tsu variants without rewriting punctuation',
    () {
      const samples = {
        'あ……っ、待って！': 'あ……、待って！',
        'あ...つ。': 'あ...。',
        'あ⋯ッツ、待って。': 'あ⋯、待って。',
        'あ．．っつっ！': 'あ．．！',
        'あ‥っ もっと': 'あ‥ もっと',
        'あ…\u200bっ。': 'あ…\u200b。',
        'あ……っ\n続けよう。': 'あ……\n続けよう。',
        '莱莎：っ……': '莱莎：……',
        'ッ、待って。': '、待って。',
        '莱莎：[happy][face:happy]っ……': '莱莎：[happy][face:happy]……',
      };
      for (final entry in samples.entries) {
        expect(filterJapaneseDialogueArtifacts(entry.key), entry.value);
        expect(filterJapaneseDialogueArtifacts(entry.value), entry.value);
      }
    },
  );

  test('ordinary tsu, gemination and quoted continuations remain exact', () {
    const samples = [
      '待って、もっとゆっくり。いつも一つずつ。',
      '「つ」「っ」は日本語の文字です。',
      '……って言ったよね。',
      '……[whispering]って言ったよね。',
      '…っ[soft voice]て言った。',
      '…つづく。…つつある。',
      '…っつう話だった。',
      '一つ……見つかった。',
      'レッツゴー！ツナサンドを作ろう。',
      'あっ、そうだった！えっ……？',
    ];
    for (final text in samples) {
      expect(filterJapaneseDialogueArtifacts(text), text);
    }
  });

  test('inline cues and their Japanese text survive artifact removal', () {
    expect(
      filterJapaneseDialogueArtifacts('あ…[つぶやき] っ[short pause]っ。'),
      'あ…[つぶやき] [short pause]。',
    );
  });

  test('cumulative streaming hides a breath but can restore a real quote', () {
    const partial = '莱莎：あ……っ';
    expect(displayTextForAssistantResponse(partial), '莱莎：あ……');
    expect(displayTextForAssistantResponse('$partial、待って。'), '莱莎：あ……、待って。');
    expect(displayTextForAssistantResponse('$partialて言った。'), '莱莎：あ……って言った。');
    const tagged = '莱莎：……っ[whispering]';
    expect(displayTextForAssistantResponse(tagged), '莱莎：……');
    expect(displayTextForAssistantResponse('$taggedて言った。'), '莱莎：……って言った。');
  });

  test('parsed, plain and raw dialogue share the display filter', () {
    const source =
        '旁白：あ……っ。\n莱莎：[happy][face:happy][action:none]あ...つ、待って！\n译文：啊……っ，等一下！';
    final segments = parseAssistantSegments(source);
    expect(
      segments.map((segment) => segment.text).join('\n'),
      isNot(matches(RegExp(r'(?:…+|\.{2,})[っつ]'))),
    );
    expect(
      displayTextForAssistantSegment(
        const ChatSegment(speaker: ChatSpeaker.ryza, text: '[happy]あ……っ、待って！'),
      ),
      'あ……、待って！',
    );
    for (final raw in [true, false]) {
      expect(
        conversationTextForAssistantResponse(source, showRawOutput: raw),
        isNot(contains('……っ')),
      );
    }
    expect(source, contains('……っ')); // Presentation does not mutate history.
  });
}
